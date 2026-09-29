#!/bin/bash
# Shared helpers for /review-prs slash command orchestrator.
# Source this file at the top of each Bash tool call that needs it.

# Target repo + checkout are auto-detected from the current working directory.
# Run the /loop session from inside the dedicated review clone — a throwaway
# checkout: each tick (and after each PR) force-resets it to match origin/main
# exactly (see pr_review_reset_tree). gh detects the repo (owner/name) from the
# clone's origin remote.
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
REVIEW_MARKER="<!-- claude-pr-review -->"
# Code (this lib + review-task.md) ships in the plugin; mutable runtime state
# (locks, logs, per-PR state) lives under BASE_DIR, OUTSIDE the plugin cache
# (which is wiped on reinstall). REVIEW_TASK_FILE resolves next to this script.
BASE_DIR="$HOME/.claude/pr-review"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Locate review-task.md (ships beside this script in the plugin). Prefer the
# plugin root the command exports; fall back to this script's own dir.
if [ -n "${REVIEW_TASK_FILE:-}" ]; then
    :
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/review-task.md" ]; then
    REVIEW_TASK_FILE="$CLAUDE_PLUGIN_ROOT/review-task.md"
else
    REVIEW_TASK_FILE="$(cd "$LIB_DIR/.." && pwd)/review-task.md"
fi
# fu-tools layered config (the repo standard), used only for notifications.
FU_CONFIG_SH="$LIB_DIR/fu-config.sh"
# Namespace lock/state/log per repo so concurrent loops on different remotes
# don't contend on one lock, and PR-number-keyed state files don't collide
# across repos (e.g. owner-a/repo PR #5 vs owner-b/repo PR #5).
REPO_SLUG="$(printf '%s' "${REPO:-unknown}" | tr '/' '-')"
STATE_DIR="$BASE_DIR/state/$REPO_SLUG"
# Auto-approve is OPT-IN. By default every review posts as COMMENT, even when the
# sub-agent found zero BLOCKERs: an APPROVE is a durable, outward-facing GitHub
# signal (it can satisfy branch protection and unblock a merge), so it has to be
# asked for. Enable it for a tick with `/review-prs --auto-approve`, or by setting
# PR_REVIEW_AUTO_APPROVE=1. The mode is recorded on DISK for the tick so the post
# step reads it back the same way it reads the findings — a mid-tick compaction
# can never flip a COMMENT tick into an approving one.
AUTO_APPROVE_FILE="$STATE_DIR/auto-approve"
LOG_FILE="$BASE_DIR/review-$REPO_SLUG.log"
LOCK_FILE="$BASE_DIR/review-prs-$REPO_SLUG.lock"
HOLDER_FILE="$BASE_DIR/review-prs-$REPO_SLUG.lock.holder"
MAX_LOG_BYTES=128000

mkdir -p "$STATE_DIR"

# ── Per-PR state store ─────────────────────────────────────────────────────────
# pr_path is the ONE place that knows the per-PR file names under STATE_DIR:
#   reviewed  last-reviewed-<pr>        record of the last posted review (durable)
#   carried   last-findings-<pr>.json   the findings still live after that review,
#                                       for the next DELTA (durable)
#   pending   pending-<pr>              record of the head pre-flight dispatched —
#                                       the PROCEED token pr_review_finish requires
#   scope     scope-<pr>.txt            what the sub-agent reviews (write_review_scope)
#   prior     prior-<pr>.json           the carried findings, for DELTA mode
#   findings  findings-<pr>.json        the sub-agent's findings
# `reviewed` and `carried` outlive a dispatch (DURABLE_KINDS, removed by purge
# once the PR closes); the rest live for one dispatch (TRANSIENT_KINDS).
DURABLE_KINDS="reviewed carried"
TRANSIENT_KINDS="pending scope prior findings"

pr_path() {
    local kind=$1 pr=$2
    case $kind in
        reviewed) printf '%s/last-reviewed-%s\n'      "$STATE_DIR" "$pr" ;;
        carried)  printf '%s/last-findings-%s.json\n' "$STATE_DIR" "$pr" ;;
        pending)  printf '%s/pending-%s\n'            "$STATE_DIR" "$pr" ;;
        scope)    printf '%s/scope-%s.txt\n'          "$STATE_DIR" "$pr" ;;
        prior)    printf '%s/prior-%s.json\n'         "$STATE_DIR" "$pr" ;;
        findings) printf '%s/findings-%s.json\n'      "$STATE_DIR" "$pr" ;;
        *) return 1 ;;
    esac
}

# A record (kinds `reviewed` and `pending`) is key=value lines: commit, tree, and
# for `reviewed` the time GitHub recorded the review. record_write <kind> <pr>
# <commit> <tree> [reviewed_at]
record_write() {
    local kind=$1 pr=$2 commit=$3 tree=$4 at=${5:-} f
    f=$(pr_path "$kind" "$pr") || return 1
    # 2>/dev/null first, so a failed open's own error stays off stderr (which
    # lands in the orchestrator's context); callers act on the return status.
    {
        printf 'commit=%s\ntree=%s\n' "$commit" "$tree"
        if [ -n "$at" ]; then printf 'reviewed_at=%s\n' "$at"; fi
    } 2>/dev/null > "$f"
}

# Print "<commit>\t<tree>\t<reviewed_at>", or return 1 when the record is absent
# or incomplete. Also reads the legacy two-line commit/tree shape (≤ v0.5.0); a
# `reviewed` record without reviewed_at falls back to the file's mtime, which is
# what detection used before reviewed_at existed. record_read <kind> <pr>
record_read() {
    local kind=$1 pr=$2 f line commit="" tree="" at=""
    f=$(pr_path "$kind" "$pr") || return 1
    [ -f "$f" ] || return 1
    if head -n 1 "$f" | grep -q '^commit='; then
        while IFS= read -r line; do
            case $line in
                commit=*)      commit=${line#commit=} ;;
                tree=*)        tree=${line#tree=} ;;
                reviewed_at=*) at=${line#reviewed_at=} ;;
            esac
        done < "$f"
    else
        { read -r commit; read -r tree; } < "$f"
    fi
    [ -n "$commit" ] && [ -n "$tree" ] || return 1
    if [ -z "$at" ] && [ "$kind" = reviewed ]; then
        at=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    fi
    printf '%s\t%s\t%s\n' "$commit" "$tree" "$at"
}

# Remove every transient file of one PR's dispatch. pr_clear <pr>
pr_clear() {
    local pr=$1 kind
    for kind in $TRANSIENT_KINDS; do rm -f "$(pr_path "$kind" "$pr")" 2>/dev/null; done
    return 0   # best-effort: an unremovable entry must not fail the caller
}

# Print this PR's namespaced state paths, for dispatch_prompt to inject into the
# review sub-agent's prompt (the sub-agent must not derive its own).
pr_review_paths() {
    local pr=$1
    printf 'SCOPE_FILE=%s\nPRIOR_FILE=%s\nFINDINGS_FILE=%s\n' \
        "$(pr_path scope "$pr")" "$(pr_path prior "$pr")" "$(pr_path findings "$pr")"
}

rotate_log() {
    local file=$1
    if [ -f "$file" ] && [ "$(stat -c%s "$file" 2>/dev/null || echo 0)" -ge "$MAX_LOG_BYTES" ]; then
        mv -f "$file" "${file}.old"
    fi
}

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    # File only, never stderr: the Bash tool captures stderr into the
    # orchestrator's context, which a /loop session accumulates tick after tick.
    printf '%s\n' "$line" >> "$LOG_FILE"
}

GH_USER=""
get_gh_user() {
    if [ -z "$GH_USER" ]; then
        GH_USER=$(gh api user --jq '.login' 2>/dev/null || true)
    fi
    echo "$GH_USER"
}

react_looking_eyes() {
    local pr=$1
    gh api "repos/$REPO/issues/$pr/reactions" \
        --method POST -f content=eyes >/dev/null 2>&1 || true
}

# Remove our own 👀 once the review is posted — it means "review in progress",
# not "seen". Only our reaction: other people's eyes stay. Best-effort.
clear_looking_eyes() {
    local pr=$1 me id
    me=$(get_gh_user)
    [ -z "$me" ] && return 0
    gh api "repos/$REPO/issues/$pr/reactions?content=eyes" --paginate \
        --jq ".[] | select(.user.login == \"$me\") | .id" 2>/dev/null |
    while read -r id; do
        [ -n "$id" ] && gh api "repos/$REPO/issues/$pr/reactions/$id" \
            --method DELETE >/dev/null 2>&1
    done
    return 0
}

get_pr_head_info() {
    local pr=$1
    local head_sha
    head_sha=$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) || return 1
    [ -z "$head_sha" ] && return 1
    local tree_sha
    tree_sha=$(gh api "repos/$REPO/commits/$head_sha" --jq '.commit.tree.sha' 2>/dev/null) || return 1
    [ -z "$tree_sha" ] && return 1
    printf '%s\t%s\n' "$head_sha" "$tree_sha"
}

# ── Findings ───────────────────────────────────────────────────────────────────
# The sub-agent's whole deliverable is findings-<pr>.json:
#   {"findings": [{"severity": "BLOCKER"|"NIT", "text": "…", "where": "path:line"}],
#    "prior":    [{"status": "RESOLVED"|"STILL OPEN"|"REINTRODUCED",
#                  "severity": …, "text": …, "where": …}]}
# `where` is optional; `prior` is present only in DELTA mode. Everything derived
# from it is bash: the posted body, the verdict, and the blocker count. So the
# count can no longer disagree with the body it links to, which it did when both
# were parsed back out of sub-agent prose (EntityPlatform #2172: a RESOLVED prior
# blocker notified as "1 blocker(s)" over a body saying "No blockers found").
#
# A current blocker is a BLOCKER in `findings`, or a prior BLOCKER that is not
# RESOLVED. The verdict is APPROVE exactly when there are none.
FINDINGS_JQ='
def item_errors:
    if type != "object" then ["not an object"] else
      (if .severity == "BLOCKER" or .severity == "NIT" then []
       else ["severity must be BLOCKER or NIT"] end)
    + (if (.text | type) == "string" and (.text | test("\\S")) then []
       else ["text must be a non-empty string"] end)
    + (if (.where // "" | type) == "string" then [] else ["where must be a string"] end)
    end;
def status_errors:
    if type == "object" and (.status | IN("RESOLVED", "STILL OPEN", "REINTRODUCED")) then []
    else ["status must be RESOLVED, STILL OPEN or REINTRODUCED"] end;
def errors:
    if type != "object" then ["not a JSON object"] else
      (if (.findings | type) != "array" then ["findings must be an array"]
       else [.findings | to_entries[] | .key as $i
             | .value | item_errors[] | "findings[\($i)]: \(.)"] end)
    + (if (.prior // [] | type) != "array" then ["prior must be an array"]
       else [.prior // [] | to_entries[] | .key as $i
             | .value | (item_errors + status_errors)[] | "prior[\($i)]: \(.)"] end)
    end;
def flat: gsub("[\\r\\n]+"; " ") | sub("^\\s+"; "") | sub("\\s+$"; "");
def clean: {severity, text: (.text | flat)}
         + ((.where // "" | flat) as $w | if $w != "" then {where: $w} else {} end);
def normalize:
    {findings: [.findings[] | clean],
     prior: [.prior // [] | .[] | {status} + clean]};
def live_prior: [.prior[] | select(.status != "RESOLVED")];
def blockers: [(.findings + live_prior)[] | select(.severity == "BLOCKER")] | length;
def carried: {findings: (.findings + [live_prior[] | del(.status)])};
def line: "[\(.severity)] \(.text)" + (if .where then " — `\(.where)`" else "" end);
def numbered: to_entries | map("\(.key + 1). \(.value)") | join("\n");
def body($pr):
    "### Code review — PR #\($pr)\n"
    + (if (.prior | length) > 0
       then "Prior findings:\n" + ([.prior[] | "\(.status) — \(line)"] | numbered) + "\n\n"
       else "" end)
    + "Found \(.findings | length) issues:"
    + (if (.findings | length) > 0 then "\n" + ([.findings[] | line] | numbered) else "" end);
'

# Validate and normalize a findings file. Prints the normalized JSON, or returns
# 1 printing why it was rejected. Strict: one bad item rejects the whole file,
# since a review with a finding silently dropped is worse than one retried next
# tick. findings_load <file>
findings_load() {
    local f=$1 err
    [ -s "$f" ] || { printf 'no findings file'; return 1; }
    if ! err=$(jq -rs "$FINDINGS_JQ"'
            if length != 1 then "expected one JSON object" else .[0] | errors[] end' \
            "$f" 2>&1); then
        printf 'not valid JSON: %s' "$err"; return 1
    fi
    [ -z "$err" ] || { printf '%s' "$err" | paste -sd ';' - | sed 's/;/; /g'; return 1; }
    jq -c "$FINDINGS_JQ"'normalize' "$f"
}

# Queries over normalized findings (findings_load's output) on stdin.
findings_blockers() { jq -r "$FINDINGS_JQ"'blockers'; }
findings_body()     { jq -r --arg pr "$1" "$FINDINGS_JQ"'body($pr)'; }   # findings_body <pr>
# What the next DELTA review re-checks: this review's findings plus the prior
# ones still open or reintroduced. A RESOLVED finding is done with.
findings_carried()  { jq -c "$FINDINGS_JQ"'carried'; }

# Write prior-<pr>.json for the sub-agent: {"findings": [...]}, from the findings
# carried by our last posted review. A review posted before findings were carried
# (≤ v0.6.0) has none, so its text from GitHub rides along as `legacy_body`.
write_prior_findings() {
    local pr=$1 carried legacy
    carried=$(pr_path carried "$pr")
    if jq -e '.findings | type == "array"' "$carried" >/dev/null 2>&1; then
        jq '{findings}' "$carried"
    else
        legacy=$(fetch_prior_findings "$pr")
        if grep -q '[^[:space:]]' <<< "$legacy"; then
            jq -n --arg b "$legacy" '{findings: [], legacy_body: $b}'
        else
            jq -n '{findings: []}'
        fi
    fi > "$(pr_path prior "$pr")"
}

# Record this tick's auto-approve mode from the command's arguments. Called by
# pr_review_init ONLY after the lock is held, so a LOCKED tick can never rewrite
# the running tick's mode. Absent flag => the file is removed, i.e. every tick
# re-declares its mode and a stale flag cannot leak into a later tick.
pr_review_set_mode() {
    local want=0 a
    for a in "$@"; do
        case "$a" in
            "") ;;
            --auto-approve|--approve) want=1 ;;
            *) log "WARNING: ignoring unrecognised argument '$a'" ;;
        esac
    done
    [ "${PR_REVIEW_AUTO_APPROVE:-0}" = "1" ] && want=1
    if [ "$want" = 1 ]; then
        : > "$AUTO_APPROVE_FILE"
        log "auto-approve ENABLED — a review with zero BLOCKERs will post as APPROVE"
    else
        rm -f "$AUTO_APPROVE_FILE"
        log "auto-approve off (default) — every review posts as COMMENT"
    fi
}

auto_approve_enabled() { [ -f "$AUTO_APPROVE_FILE" ]; }

# ---------------------------------------------------------------------------
# Notifications
#
# The bot posts reviews as YOUR GitHub account, and GitHub never notifies you
# about your own actions — so without this, a completed review is invisible
# until you read the log. Channels are opt-in via fu-tools config (the repo
# standard); no config means silent, which is the historical behaviour:
#
#   { "review-prs": { "notify": ["teams"],
#                     "teams_webhook": "https://…/triggers/manual/…&sig=…" } }
#
# The webhook URL is a bearer credential (anyone holding it can post to the
# chat), so it belongs in USER config (~/.claude/fu-tools/config.json, 0600) and
# is never logged, echoed, or included in an error message here.
#
# Every channel is best-effort and time-bounded: a notifier that fails, hangs,
# or is misconfigured must never fail a tick or block the next PR.
# ---------------------------------------------------------------------------

# Read a review-prs key from the fu-tools layered config. Arrays come back one
# element per line. Missing config/script/key -> nothing.
fu_cfg() {
    [ -f "$FU_CONFIG_SH" ] || return 0
    bash "$FU_CONFIG_SH" review-prs "$1" 2>/dev/null || true
}

# Collect the facts of one outcome into a JSON object. Channels render FROM this,
# so adding a channel never means re-deriving the facts. The PR title costs one
# extra gh call and is best-effort — a notification is worth sending without it.
# notify_event <kind> <pr> <blockers> <decision> <detail>
#   kind: clean | blockers | failed | nobody
notify_event() {
    local kind=$1 pr=$2 blockers=$3 decision=$4 detail=$5 title
    title=$(gh pr view "$pr" --repo "$REPO" --json title --jq '.title' 2>/dev/null || true)
    jq -n --arg kind "$kind" --arg repo "$REPO" --arg pr "$pr" --arg title "$title" \
          --arg decision "$decision" --arg blockers "$blockers" --arg detail "$detail" \
          --arg url "https://github.com/$REPO/pull/$pr" \
          '{kind:$kind, repo:$repo, pr:$pr, title:$title,
            decision:$decision, blockers:$blockers, detail:$detail, url:$url}'
}

# POST to a Power Automate ("Workflows") webhook. The body carries the same
# content three ways, so ONE payload fits whichever shape the flow was built in:
#   text         — HTML. Teams' "Post message in a chat or channel" action renders
#                  <b>/<i>/<br>/<a>/<ul> and ignores markdown. (Measured.)
#   messageJson  — the full {type,summary,attachments} envelope PRE-SERIALIZED, for
#                  a DIRECT channel webhook, which honours `summary` as the
#                  notification preview. The flowbot action does NOT take it: it
#                  wants a bare card and answers "adaptive card request is missing
#                  or invalid" (tested), so `summary` cannot reach Teams that way.
#   cardJson     — the bare card PRE-SERIALIZED, for a "Post card in a chat or
#                  channel" action. Serializing here rather than with the flow's
#                  string() avoids "message body is invalid JSON" on an untyped
#                  field. Cards posted this way always preview as "sent a card".
#   card         — the same card as a JSON object, for flows that want one.
#   attachments  — the same card in the {type:"message",attachments:[…]} envelope
#                  the ready-made Workflows templates consume.
# All interpolated values go through @html — a PR title containing < & > must not
# be able to inject markup.
notify_teams() {
    local ev=$1 hook code payload
    hook=$(fu_cfg teams_webhook | head -n1)
    if [ -z "$hook" ]; then
        log "notify: 'teams' selected but review-prs.teams_webhook is unset — skipping"
        return 0
    fi
    payload=$(jq -n --argjson e "$ev" '
        ($e.kind) as $k
        | (if $k == "blockers" then "🚧"
           elif $k == "clean"  then "✅"
           elif $k == "failed" then "❌"
           else "⚠️" end) as $icon
        | (if $k == "blockers" then "Attention"
           elif $k == "clean"  then "Good"
           else "Warning" end) as $colour
        | (if $k == "blockers" then ($e.blockers + " blocker(s)")
           elif $k == "clean"  then "no blockers"
           elif $k == "failed" then "POST to GitHub failed"
           else "no review body produced" end) as $summary
        # Headline uses the bare repo name — the owner eats toast width and never
        # varies in practice. The full owner/name stays in the FactSet.
        | ($e.repo | split("/") | last) as $repo_short
        | ($repo_short + " PR #" + $e.pr + " — " + $summary) as $headline
        | ([ (if $e.decision != "" then "posted " + $e.decision else empty end),
             (if $e.detail   != "" then $e.detail else empty end) ]
           | join(" · ")) as $meta
        | ([ "<b>" + ($icon + " " + $headline | @html) + "</b>",
             (if $e.title != "" then "<i>" + ($e.title | @html) + "</i>" else empty end),
             ($meta | @html),
             "<a href=\"" + ($e.url | @html) + "\">Open PR</a>" ]
           | join("<br>")) as $html
        | ([ ($icon + " " + $headline), $meta ] | join(" · ")) as $plain
        | ({
            type: "AdaptiveCard",
            version: "1.4",
            # For clients that cannot render the card. NOT a notification summary:
            # Teams previews a bot-posted card as "sent a card" regardless (tested),
            # which is why the HTML `text` shape is the recommended one.
            fallbackText: $plain,
            body: ([
                { type: "TextBlock", text: ($icon + " " + $headline),
                  weight: "Bolder", size: "Medium", color: $colour, wrap: true }
            ] + (if $e.title != ""
                 then [{ type: "TextBlock", text: $e.title, wrap: true, isSubtle: true, spacing: "None" }]
                 else [] end)
              + [{ type: "FactSet", facts: ([
                    { title: "Repo", value: $e.repo }
                  ] + (if $e.decision != "" then [{ title: "Posted", value: $e.decision }] else [] end)
                    + (if $e.kind == "blockers" then [{ title: "Blockers", value: $e.blockers }] else [] end)
                    + (if $e.detail != "" then [{ title: "Note", value: $e.detail }] else [] end)) }]),
            actions: [{ type: "Action.OpenUrl", title: "Open PR", url: $e.url }]
        }) as $card
        | ({
            type: "message",
            # The notification preview. It belongs on the message/attachment
            # envelope — a `summary` inside the Adaptive Card does nothing, which
            # is why a bot-posted card otherwise previews as "sent a card".
            summary: $plain,
            attachments: [{
                contentType: "application/vnd.microsoft.card.adaptive",
                summary: $plain,
                content: $card
            }]
        }) as $msg
        | $msg + {
            text: $html,
            card: $card,
            cardJson: ($card | tojson),
            messageJson: ($msg | tojson)
        }')
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
        -H 'Content-Type: application/json' --data-binary "$payload" "$hook" 2>/dev/null) \
        || code="000"
    case "$code" in
        2*) log "notify: teams ok (http $code)" ;;
        *)  log "notify: teams FAILED (http $code)" ;;  # never log the URL itself
    esac
}

# Fan one outcome out to every configured channel. Called at the points where a
# tick's outcome becomes final: a posted review, or a failure to post. Returns
# immediately (no gh call, no work) when no channel is configured.
# pr_review_notify <kind> <pr> <blockers> <decision> <detail>
pr_review_notify() {
    local channels ev ch
    channels=$(fu_cfg notify)
    [ -z "$channels" ] && return 0
    ev=$(notify_event "$@")
    while IFS= read -r ch; do
        case "$ch" in
            "")      ;;
            teams)   notify_teams "$ev" ;;
            bell)    printf '\a' >&2 ;;
            *)       log "notify: unknown channel '$ch' in review-prs.notify — skipping" ;;
        esac
    done <<< "$channels"
}

fetch_prior_findings() {
    local pr=$1
    gh api "repos/$REPO/pulls/$pr/reviews" 2>/dev/null \
        | jq -r --arg marker "$REVIEW_MARKER" '
            [.[] | select((.body // "") | contains($marker))]
            | sort_by(.submitted_at) | last | .body // ""' 2>/dev/null \
        | sed -e "s|$REVIEW_MARKER||" -e '/^\*Automated review by Claude Code/d' \
        || true
}

# Outputs "PR_NUM REASON" lines for PRs that need review.
# REASON is review_requested or review_re_requested.
# Prints nothing for PRs that should be skipped.
detect_queued_prs() {
    local gh_user
    gh_user=$(get_gh_user)
    [ -z "$gh_user" ] && return 1

    local requested_prs
    requested_prs=$(gh pr list --repo "$REPO" --state open \
        --json number,reviewRequests \
        --jq "[.[] | select(.reviewRequests | map(.login) | index(\"$gh_user\")) | .number] | .[]" \
        2>/dev/null || true)

    [ -z "$requested_prs" ] && return 0

    while IFS= read -r pr; do
        [ -z "$pr" ] && continue
        local rec
        # Case A: never reviewed (or state record lost)
        if ! rec=$(record_read reviewed "$pr"); then
            # Check if our marker already exists on GH (lost state file recovery)
            local last_review_ts
            last_review_ts=$(gh api "repos/$REPO/pulls/$pr/reviews" 2>/dev/null \
                | jq -r --arg marker "$REVIEW_MARKER" \
                    '[.[] | select((.body // "") | contains($marker))] | max_by(.submitted_at) | .submitted_at // empty')
            if [ -z "$last_review_ts" ]; then
                # No prior review — queue as first review
                echo "$pr review_requested"
                continue
            fi
            # Marker exists — check for re-request after our last review (dismiss+re-request pattern)
            local last_req_ts_a
            last_req_ts_a=$(gh api "repos/$REPO/issues/$pr/events?per_page=100" 2>/dev/null \
                | jq -r --arg me "$gh_user" '
                    [.[] | select(.event == "review_requested"
                                  and (.requested_reviewer.login // "") == $me)]
                    | max_by(.created_at) | .created_at // empty')
            if [ -n "$last_req_ts_a" ] && [[ "$last_req_ts_a" > "$last_review_ts" ]]; then
                log "PR #$pr: re-requested at $last_req_ts_a after lost-state review at $last_review_ts — queueing"
                echo "$pr review_re_requested"
            fi
            continue
        fi

        # Case B: reviewed before — queue only on explicit re-request
        local last_req_ts
        last_req_ts=$(gh api "repos/$REPO/issues/$pr/events?per_page=100" 2>/dev/null \
            | jq -r --arg me "$gh_user" '
                [.[] | select(.event == "review_requested"
                              and (.requested_reviewer.login // "") == $me)]
                | max_by(.created_at) | .created_at // empty')
        [ -z "$last_req_ts" ] && continue

        local reviewed_at
        reviewed_at=$(cut -f3 <<< "$rec")
        [ -z "$reviewed_at" ] && continue

        if [[ "$last_req_ts" > "$reviewed_at" ]]; then
            log "PR #$pr: re-requested at $last_req_ts (reviewed at $reviewed_at) — queueing"
            echo "$pr review_re_requested"
        fi
    done <<< "$requested_prs"
}

# Remove stale temp files and state files for closed PRs. Safe to call anytime.
pr_review_purge_stale() {
    local open_prs name prefix suffix f pr kind
    open_prs=$(gh pr list --repo "$REPO" --state open --json number --jq '.[].number' 2>/dev/null || true)
    # File names come from pr_path with a `*` PR, so this knows no names itself.
    for kind in $DURABLE_KINDS; do
        name=$(basename "$(pr_path "$kind" '*')")
        prefix=${name%%\**} suffix=${name#*\*}
        for f in "$STATE_DIR"/$name; do
            [ -e "$f" ] || continue
            pr=${f##*/}; pr=${pr#"$prefix"}; pr=${pr%"$suffix"}
            grep -qx -- "$pr" <<< "$open_prs" || rm -f "$f"
        done
    done
    for kind in $TRANSIENT_KINDS; do
        name=$(basename "$(pr_path "$kind" '*')")
        for f in "$STATE_DIR"/$name; do rm -f "$f"; done
    done
    # Transients of kinds retired in v0.7.0 (body, decision, prose prior), which
    # pr_path no longer names — left behind by a tick that ran before the upgrade.
    rm -f "$STATE_DIR"/review-body-*.md "$STATE_DIR"/decision-*.txt "$STATE_DIR"/prior-*.txt
}

# Release the lock held by the background holder process.
pr_review_release_lock() {
    if [ -f "$HOLDER_FILE" ]; then
        kill "$(cat "$HOLDER_FILE")" 2>/dev/null || true
        rm -f "$HOLDER_FILE"
    fi
}

# Force the dedicated review clone back to a clean, up-to-date main. The clone
# is a throwaway per-project checkout, so discarding working-tree changes — both
# tracked mods AND untracked files — is safe and intended. A sub-agent's
# `gh pr checkout <PR>` leaves the clone on the PR branch; switching back to main
# strands any files the PR added as untracked, and a plain `git checkout main`
# aborts on the resulting dirty tree. Force-reset so every tick / next PR starts
# pristine. Called from pr_review_init (tick start) and pr_review_finish (per PR).
pr_review_reset_tree() {
    git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    local git_err
    # fetch + hard-reset (not pull): the working dir is made to match origin/main
    # EXACTLY, immune to local divergence or a force-pushed/rewritten remote main.
    git_err=$(git -C "$REPO_DIR" fetch origin main --quiet 2>&1) \
        || log "WARNING: 'git fetch origin main' failed in $REPO_DIR: $git_err"
    git_err=$(git -C "$REPO_DIR" checkout -f main --quiet 2>&1) \
        || log "WARNING: 'git checkout -f main' failed in $REPO_DIR: $git_err"
    git_err=$(git -C "$REPO_DIR" reset --hard origin/main --quiet 2>&1) \
        || log "WARNING: 'git reset --hard origin/main' failed in $REPO_DIR: $git_err"
    git_err=$(git -C "$REPO_DIR" clean -fd --quiet 2>&1) \
        || log "WARNING: 'git clean -fd' failed in $REPO_DIR: $git_err"
    # Prune stale local branches left by sub-agents' `gh pr checkout` (everything
    # but main). Otherwise a re-checkout of the same PR after a force-push hits a
    # diverged local ref and needs --force. Safe: this is a dedicated throwaway
    # clone whose only durable branch is main.
    local stale
    stale=$(git -C "$REPO_DIR" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null \
        | grep -vx main || true)
    if [ -n "$stale" ]; then
        printf '%s\n' "$stale" | xargs -r git -C "$REPO_DIR" branch -D >/dev/null 2>&1 || true
        log "pruned $(printf '%s\n' "$stale" | grep -c .) stale local branch(es)"
    fi
}

# Acquire lock, setup, purge stale files, detect queued PRs. Pass the command's
# arguments through (`pr_review_init $ARGUMENTS`) — `--auto-approve` is the only
# one recognised, and it is recorded on disk for this tick.
# Outputs: "LOCKED", "NO_WORK", or "PR_NUM REASON" lines.
# On LOCKED or NO_WORK the lock is already released — the caller is done.
pr_review_init() {
    (flock -n 9 || exit 1; sleep 7200) 9>"$LOCK_FILE" &
    local holder=$!
    sleep 0.3
    if ! kill -0 "$holder" 2>/dev/null; then
        echo "LOCKED"
        return 0
    fi
    echo "$holder" > "$HOLDER_FILE"

    rotate_log "$LOG_FILE"
    log "=== PR review check started ==="

    if [ -z "$REPO" ]; then
        log "ERROR: could not detect target repo from $PWD — run the loop from inside the review clone"
        log "=== PR review check complete ==="
        pr_review_release_lock
        echo "NO_WORK"
        return 0
    fi
    log "Target repo: $REPO (checkout: $REPO_DIR)"
    # After the REPO check, so the flag always lands in the right repo's state dir
    # (and an undetected-repo bail writes no flag at all).
    pr_review_set_mode "$@"
    # Refresh the ambient-context baseline that /code-review's sub-agents read
    # (CLAUDE.md, neighbouring code). Force-reset to clean main: a prior tick's
    # sub-agent may have left the clone on a PR branch with stray untracked files.
    pr_review_reset_tree

    pr_review_purge_stale

    local queued
    queued=$(detect_queued_prs)
    if [ -z "$queued" ]; then
        log "No PRs to review"
        log "=== PR review check complete ==="
        rm -f "$AUTO_APPROVE_FILE"
        pr_review_release_lock
        echo "NO_WORK"
    else
        printf '%s\n' "$queued"
    fi
}

# Decide what the sub-agent reviews and write it to scope-<pr>.txt: a key=value
# header (REPO, HEAD, MODE, DELTA_BASE), a blank line, then one file per line.
# Keyed on the tree SHA, like the review state: no state or an unchanged tree
# (a re-request) → FULL, every PR file; a changed tree → DELTA, the PR's files ∩
# the files changed since the last reviewed commit (not the raw compare, which
# carries rebased-in main commits). Any uncertain delta — empty, compare failed,
# compare at its 300-file cap — falls back to FULL: a wider review is only ever
# a comment. Returns 1 (pre-flight SKIPs) only when the PR's own file list can't
# be fetched. The list goes to disk, never stdout (orchestrator context).
write_review_scope() {
    local pr=$1 commit=$2 tree=$3
    local pr_files files="" mode=FULL base="" why="first review" scope_file
    scope_file=$(pr_path scope "$pr")
    rm -f "$scope_file"
    pr_files=$(gh api "repos/$REPO/pulls/$pr/files" --paginate --jq '.[].filename' 2>/dev/null) || return 1
    pr_files=$(printf '%s\n' "$pr_files" | grep . | LC_ALL=C sort -u)
    [ -z "$pr_files" ] && return 1

    local rec last_commit last_tree _at
    if rec=$(record_read reviewed "$pr"); then
        IFS=$'\t' read -r last_commit last_tree _at <<< "$rec"
        if [ "$last_tree" = "$tree" ]; then
            why="tree unchanged"
        else
            local delta_files
            if ! delta_files=$(gh api "repos/$REPO/compare/${last_commit}...${commit}" \
                    --jq '.files[].filename' 2>/dev/null); then
                why="compare $last_commit...$commit failed"
            elif [ "$(printf '%s\n' "$delta_files" | grep -c .)" -ge 300 ]; then
                why="compare hit its 300-file cap"
            else
                files=$(LC_ALL=C comm -12 <(printf '%s\n' "$pr_files") \
                    <(printf '%s\n' "$delta_files" | grep . | LC_ALL=C sort -u))
                if [ -n "$files" ]; then
                    mode=DELTA base=$last_commit why="tree changed"
                else
                    why="no PR file changed since $last_commit"
                fi
            fi
        fi
    fi
    [ "$mode" = FULL ] && files=$pr_files

    { printf 'REPO=%s\nHEAD=%s\nMODE=%s\nDELTA_BASE=%s\n\n' "$REPO" "$commit" "$mode" "$base"
      printf '%s\n' "$files"; } > "$scope_file"
    log "PR #$pr: $mode review ($why), $(printf '%s\n' "$files" | grep -c .) file(s)"
}

# Pre-flight check for a single PR. Outputs "SKIP", or "PROCEED" followed by the
# sub-agent's Task prompt. On PROCEED it has written everything the rest of the
# PR's run reads from disk — scope-<pr>.txt (what to review, for the sub-agent),
# prior-<pr>.json (prior findings), and pending-<pr> (the reviewed commit/tree,
# for the post step) — so the handoff survives a mid-tick compaction.
pr_review_preflight() {
    local pr=$1 reason=$2

    log "Processing PR #$pr (reason: $reason)"

    local pr_info pr_author pr_state
    pr_info=$(gh pr view "$pr" --repo "$REPO" --json author,state 2>/dev/null || echo '{}')
    pr_author=$(jq -r '.author.login // empty' <<< "$pr_info")
    pr_state=$(jq -r '.state // empty' <<< "$pr_info")

    if [ -z "$pr_author" ]; then
        log "PR #$pr: could not fetch info, skipping"
        echo "SKIP"; return 0
    fi
    if [ "$pr_state" != "OPEN" ]; then
        log "PR #$pr: state is $pr_state, skipping"
        echo "SKIP"; return 0
    fi

    local head_info current_commit current_tree
    head_info=$(get_pr_head_info "$pr") || {
        log "PR #$pr: could not fetch head info, skipping"
        echo "SKIP"; return 0
    }
    current_commit=${head_info%%$'\t'*}
    current_tree=${head_info##*$'\t'}

    write_review_scope "$pr" "$current_commit" "$current_tree" || {
        log "PR #$pr: could not fetch the PR's file list, skipping"
        echo "SKIP"; return 0
    }

    # Pre-write prior findings for the sub-agent. Done here so the sub-agent reads
    # it from disk and never needs gh-pipe permissions of its own.
    write_prior_findings "$pr" 2>/dev/null || true

    # Clear this PR's findings so the sub-agent's run starts clean — stale
    # findings from a prior tick that never reached the post step must not be
    # read by pr_review_finish. Then persist the reviewed commit/tree: the
    # pending record is the PROCEED token pr_review_finish requires.
    rm -f "$(pr_path findings "$pr")"
    record_write pending "$pr" "$current_commit" "$current_tree" || {
        # No token, no dispatch: finish would drop the finished review as a no-op.
        log "PR #$pr: could not write the pending record, skipping"
        pr_clear "$pr"
        echo "SKIP"; return 0
    }

    # 👀 only once we know a review will run — a SKIP tick must not re-add it to
    # a PR whose posted review already cleared it (pr_review_finish).
    react_looking_eyes "$pr"

    printf 'PROCEED\n'
    dispatch_prompt "$pr"
}

# The review sub-agent's Task prompt, printed by pre-flight after PROCEED so the
# orchestrator passes it verbatim — it never assembles the prompt or holds paths.
dispatch_prompt() {
    local pr=$1
    printf 'Read %s and follow it exactly. Review PR #%s.\n' "$REVIEW_TASK_FILE" "$pr"
    printf 'Use these absolute paths verbatim — do not construct your own:\n'
    pr_review_paths "$pr" | sed 's/^\([A-Z_]*\)=/  \1 = /'
}

# Post the sub-agent's review to GitHub, then save state. Takes ONLY the PR number
# — everything else is recovered from disk, so a context compaction landing between
# pre-flight and here loses nothing: commit/tree from pending-<pr> (pre-flight),
# findings from findings-<pr>.json (sub-agent), from which the body, verdict and
# blocker count are derived here. State is saved ONLY on a successful post, so a
# failed post or a missing/invalid findings file retries next tick.
# Prints ONE status token, so the orchestrator can tell the outcomes apart without
# reading the log: POSTED <APPROVE|COMMENT>, FAILED (the POST failed),
# NO_FINDINGS (missing or invalid findings file), or NOTHING_PENDING (no PROCEED
# token). The reason for a non-POSTED outcome stays in the log only.
pr_review_finish() {
    local pr=$1 status

    # pending-<pr> is the PROCEED token: without it no review was dispatched for
    # this head (the orchestrator ran finish after a SKIP, or out of order), so
    # there is nothing to post — and no reviewed commit to record.
    local pend commit tree _at
    if ! pend=$(record_read pending "$pr"); then
        log "PR #$pr: nothing pending (pre-flight did not PROCEED) — finish is a no-op"
        pr_clear "$pr"
        pr_review_reset_tree   # still leave the clone on main for the next PR
        echo "NOTHING_PENDING"
        return 0
    fi
    IFS=$'\t' read -r commit tree _at <<< "$pend"

    local findings why
    if ! findings=$(findings_load "$(pr_path findings "$pr")"); then
        why=$findings
        log "PR #$pr: no usable findings ($why) — NOT posting, NOT saving state (will retry next tick)"
        pr_review_notify nobody "$pr" 0 "" "nothing posted, retries next tick"
        status=NO_FINDINGS
    else
        local decision=COMMENT blockers review_body downgraded=0
        blockers=$(findings_blockers <<< "$findings")
        [ "$blockers" = 0 ] && decision=APPROVE
        # Policy gate: zero BLOCKERs only makes the verdict APPROVE. Turning that
        # into a posted GitHub approval needs the opt-in flag (see
        # AUTO_APPROVE_FILE); without it the same findings post as a COMMENT.
        if [ "$decision" = "APPROVE" ] && ! auto_approve_enabled; then
            log "PR #$pr: no blockers found, but auto-approve is off — posting COMMENT"
            decision="COMMENT"
            downgraded=1
        fi
        review_body=$(findings_body "$pr" <<< "$findings")

        local footer="*Automated review by Claude Code via /code-review*"
        if [ "$downgraded" = 1 ]; then
            footer="$footer
*No blockers found. Posted as a comment, not an approval — auto-approve is off.*"
        fi

        local body
        body="$REVIEW_MARKER
$review_body

---
$footer"

        local submitted_at
        if submitted_at=$(gh api "repos/$REPO/pulls/$pr/reviews" --method POST \
                -f "event=$decision" -f "body=$body" --jq '.submitted_at // empty' 2>/dev/null); then
            log "PR #$pr: posted $decision review"
            status="POSTED $decision"
            clear_looking_eyes "$pr"
            # reviewed_at on GitHub's clock, so detection compares it against
            # GitHub's review_requested timestamps like for like.
            [ -n "$submitted_at" ] || submitted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            record_write reviewed "$pr" "$commit" "$tree" "$submitted_at"
            # Carry the live findings to the next DELTA. On a failed write, drop
            # the file rather than leave an older review's findings standing:
            # pre-flight then falls back to this review's text on GitHub.
            local carried
            carried=$(pr_path carried "$pr")
            findings_carried <<< "$findings" 2>/dev/null > "$carried" || {
                rm -f "$carried" 2>/dev/null
                log "PR #$pr: could not save the carried findings — the next DELTA reads the posted text"
            }
            if [ "$blockers" -gt 0 ] 2>/dev/null; then
                pr_review_notify blockers "$pr" "$blockers" "$decision" ""
            else
                pr_review_notify clean "$pr" 0 "$decision" ""
            fi
        else
            log "PR #$pr: FAILED to post review — NOT saving state (will retry next tick)"
            pr_review_notify failed "$pr" "$blockers" "$decision" "retries next tick"
            status=FAILED
        fi
    fi
    # Always clear this PR's transients; the next tick regenerates them.
    pr_clear "$pr"

    # Return the dedicated clone to a clean main so the next PR's sub-agent
    # (or the next tick) starts from a pristine tree, not this PR's branch.
    pr_review_reset_tree
    echo "$status"
}

# End-of-run: log completion and release the lock. Stale-file purge already
# happened in pr_review_init. Only reached on the work path (NO_WORK releases
# in init). If the agent skips this, the 7200s holder timeout releases the lock.
pr_review_cleanup() {
    log "=== PR review check complete ==="
    # Drop the tick's auto-approve flag so it cannot outlive this run. (init also
    # re-declares the mode, so this is belt-and-braces.)
    rm -f "$AUTO_APPROVE_FILE"
    pr_review_release_lock
}
