#!/bin/bash
# Shared helpers for /review-prs slash command orchestrator.
# Source this file at the top of each Bash tool call that needs it.
#
# Every GitHub read and write here is a REST `gh api` call, and the repo comes
# from the origin URL. Claude Code cloud sessions answer every GraphQL request
# with HTTP 403, and `gh repo view`, `gh pr list`, `gh pr view`,
# `gh issue view` and `gh pr checkout` are all GraphQL underneath.

# The checkout the loop runs from. In a cloud session it is the session's own
# checkout, holding the user's branch and work, so nothing here ever checks
# out, resets, cleans or deletes a branch in it: reviews run in a separate
# worktree, REVIEW_DIR, that shares its object store.
SOURCE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

# owner/name from the origin URL: https://github.com/o/r(.git),
# git@github.com:o/r.git, or a session git proxy URL ending in /o/r. Read as
# configured, before any url.<base>.insteadOf rewrite, which may point at a
# mirror or proxy whose path does not end in owner/name.
# PR_REVIEW_REPO overrides it.
repo_from_origin() {
    local url
    url=$(git -C "$SOURCE_DIR" config --get remote.origin.url 2>/dev/null) || return 0
    url=${url%/}
    url=${url%.git}
    sed -nE 's#^.*[:/]([^/:]+)/([^/:]+)$#\1/\2#p' <<< "$url"
}
REPO="${PR_REVIEW_REPO:-$(repo_from_origin)}"
REVIEW_MARKER="<!-- claude-pr-review -->"
# Each posted review also carries its own state as a hidden comment (see
# state_comment), so a fresh environment with no ~/.claude/pr-review — a cloud
# session — can still run a DELTA review with structured priors.
STATE_TAG="fu-review-state"
REVIEW_BODY_MAX=65536   # GitHub's limit on a review body, in characters
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
REVIEW_DIR="$BASE_DIR/worktrees/$REPO_SLUG"
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
#   gate      gate-<pr>.txt             the approval gate's file check: `low-risk`,
#                                       or the first PR path that is not (classify_pr_files)
#   empty     empty-<pr>                record of a head at which the PR changes no
#                                       file — detection skips it until the tree moves
#   mode      mode-<pr>                 a /review-pr run's mode: `single`, plus
#                                       `auto-approve` when asked (pr_review_one), plus
#                                       `routine` and `fanout` for a routine run
#   part_<d>  findings-<pr>.<d>.json    a FANOUT reviewer's findings for dimension <d>
#                                       (ROUTINE_DIMENSIONS), merged into `findings`
# `reviewed`, `carried` and `empty` outlive a dispatch (DURABLE_KINDS, removed by
# purge once the PR closes); the rest live for one dispatch (TRANSIENT_KINDS).
DURABLE_KINDS="reviewed carried empty"
TRANSIENT_KINDS="pending scope prior findings gate mode part_correctness part_security part_intent"

pr_path() {
    local kind=$1 pr=$2
    case $kind in
        reviewed) printf '%s/last-reviewed-%s\n'      "$STATE_DIR" "$pr" ;;
        carried)  printf '%s/last-findings-%s.json\n' "$STATE_DIR" "$pr" ;;
        pending)  printf '%s/pending-%s\n'            "$STATE_DIR" "$pr" ;;
        scope)    printf '%s/scope-%s.txt\n'          "$STATE_DIR" "$pr" ;;
        prior)    printf '%s/prior-%s.json\n'         "$STATE_DIR" "$pr" ;;
        findings) printf '%s/findings-%s.json\n'      "$STATE_DIR" "$pr" ;;
        gate)     printf '%s/gate-%s.txt\n'           "$STATE_DIR" "$pr" ;;
        empty)    printf '%s/empty-%s\n'              "$STATE_DIR" "$pr" ;;
        mode)     printf '%s/mode-%s\n'               "$STATE_DIR" "$pr" ;;
        part_*)   printf '%s/findings-%s.%s.json\n'   "$STATE_DIR" "$pr" "${kind#part_}" ;;
        *) return 1 ;;
    esac
}

# A record (kinds `reviewed`, `pending` and `empty`) is key=value lines: commit, tree, and
# for `reviewed` the time GitHub recorded the review, for `pending` the time
# pre-flight dispatched it. record_write <kind> <pr> <commit> <tree> [reviewed_at]
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

# GET every page of a REST list endpoint, printing <jq> (run with jq -r) over
# each page. Pages by explicit page=N on the repos/<owner>/<name> path, never
# `gh api --paginate`: that follows GitHub's Link: rel="next", which names the
# repo by numeric ID (repositories/<id>/...), and a Claude Code cloud session's
# GitHub proxy answers that with 403, so page 1 lands and the call fails whole.
# A short page ends the list; items are counted on the raw page, since <jq> may
# print any number of lines per item. Returns 1 if any page fails, after printing
# the pages before it. Stops at GH_PAGES_MAX pages, GitHub's own 3000-file cap
# on pulls/<n>/files. gh_api_pages <path[?query]> <jq>
GH_PER_PAGE=100
GH_PAGES_MAX=30
gh_api_pages() {
    local path=$1 filter=$2 sep='?' page=1 body n
    [[ "$path" == *\?* ]] && sep='&'
    while :; do
        body=$(gh api "${path}${sep}per_page=$GH_PER_PAGE&page=$page") || return 1
        n=$(jq 'if type == "array" then length else error("not a list") end' <<< "$body") \
            && [ -n "$n" ] || return 1
        jq -r "$filter" <<< "$body" || return 1
        [ "$n" -lt "$GH_PER_PAGE" ] && return 0
        if [ "$page" -ge "$GH_PAGES_MAX" ]; then
            log "WARNING: $path: stopped at $GH_PAGES_MAX pages of $GH_PER_PAGE"
            return 0
        fi
        page=$((page + 1))
    done
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
    gh_api_pages "repos/$REPO/issues/$pr/reactions?content=eyes" \
        ".[] | select(.user.login == \"$me\") | .id" 2>/dev/null |
    while read -r id; do
        [ -n "$id" ] && gh api "repos/$REPO/issues/$pr/reactions/$id" \
            --method DELETE >/dev/null 2>&1
    done
    return 0
}

get_pr_head_info() {
    local pr=$1
    local head_sha
    head_sha=$(gh api "repos/$REPO/pulls/$pr" --jq '.head.sha' 2>/dev/null) || return 1
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

# A /review-pr run records its mode per PR (pr_review_one), so it neither reads
# nor flips a /review-prs loop's tick-wide flag. auto_approve_enabled [pr]
auto_approve_enabled() {
    local mode
    if [ -n "${1:-}" ] && mode=$(pr_path mode "$1") && [ -f "$mode" ]; then
        grep -qx auto-approve "$mode"
        return
    fi
    [ -f "$AUTO_APPROVE_FILE" ]
}
single_run() { [ -f "$(pr_path mode "$1")" ]; }
# Mode lines a routine run adds (pr_review_one --routine). mode_has <pr> <line>
mode_has() { grep -qx "$2" "$(pr_path mode "$1")" 2>/dev/null; }

# Even with --auto-approve, only a PR whose every file is docs, tests or UI may be
# approved: a clean review of code that runs on a server is still posted as a
# COMMENT. Bash patterns, matched against the whole path, where `*` also matches
# `/` — so `*.md` is any Markdown file at any depth, and a directory needs both
# `dir/*` (at the root) and `*/dir/*` (nested). Override the whole list with the
# fu-tools array `review-prs.low_risk_paths`.
LOW_RISK_PATHS_DEFAULT=(
    # docs
    '*.md' '*.mdx' '*.markdown' '*.rst' '*.adoc'
    'docs/*' '*/docs/*' 'doc/*' '*/doc/*' 'LICENSE*' '*/LICENSE*'
    # tests
    'test/*' '*/test/*' 'tests/*' '*/tests/*' '__tests__/*' '*/__tests__/*'
    '__snapshots__/*' '*/__snapshots__/*' 'e2e/*' '*/e2e/*'
    '*Tests/*' '*Test/*' '*.test.*' '*.spec.*' '*_test.*' 'test_*.py' '*/test_*.py'
    # ui
    '*.UI/*' 'ui/*' '*/ui/*' 'frontend/*' '*/frontend/*'
    '*.ts' '*.tsx' '*.jsx' '*.vue' '*.svelte' '*.html' '*.cshtml' '*.razor'
    '*.css' '*.scss' '*.sass' '*.less'
    '*.svg' '*.png' '*.jpg' '*.jpeg' '*.gif' '*.webp' '*.ico' '*.woff' '*.woff2'
)

# Read paths on stdin, one per line. Print `low-risk` when every path matches a
# low-risk pattern, else the first path that matches none. An empty list is not
# low-risk: there is nothing to vouch for.
classify_pr_files() {
    local -a pats=()
    local f p hit n=0
    mapfile -t pats < <(fu_cfg low_risk_paths | grep .)
    [ "${#pats[@]}" -gt 0 ] || pats=("${LOW_RISK_PATHS_DEFAULT[@]}")
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1)) hit=0
        for p in "${pats[@]}"; do
            # shellcheck disable=SC2053  # $p is a pattern on purpose
            [[ $f == $p ]] && { hit=1; break; }
        done
        [ "$hit" = 1 ] || { printf '%s\n' "$f"; return 0; }
    done
    [ "$n" -gt 0 ] && echo low-risk || echo "(no files)"
}

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
    title=$(gh api "repos/$REPO/pulls/$pr" --jq '.title' 2>/dev/null || true)
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
        # The posted event, with its own emoji so APPROVE vs COMMENT reads at a
        # glance — independent of $icon, since a clean review can still be a COMMENT.
        | (if $e.decision == "APPROVE"   then "👍 APPROVE"
           elif $e.decision == "COMMENT" then "💬 COMMENT"
           else $e.decision end) as $decision
        | ($e.repo | split("/") | last) as $repo_short
        | ($repo_short + " PR #" + $e.pr + " — " + $summary) as $headline
        | ([ (if $e.decision != "" then "posted " + $decision else empty end),
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
                  ] + (if $e.decision != "" then [{ title: "Posted", value: $decision }] else [] end)
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

# ---------------------------------------------------------------------------
# Heartbeat
#
# Tells teammates a bot is running on this repo: each tick pings a Cloudflare
# Worker (worker/ in this plugin), which serves a live/dead badge per repo. Both
# keys must be set, in USER config — the token is a bearer credential and, like
# teams_webhook, is never logged:
#
#   { "review-prs": { "heartbeat_url": "https://review-bot-heartbeat.<sub>.workers.dev",
#                     "heartbeat_token": "…",
#                     "heartbeat_footer": true } }
#
# heartbeat_footer (optional) embeds this repo's badge in every review footer.
# ---------------------------------------------------------------------------

# Base URL of the heartbeat Worker, or nothing when the heartbeat is off.
heartbeat_url() {
    local url token
    url=$(fu_cfg heartbeat_url | head -n1)
    token=$(fu_cfg heartbeat_token | head -n1)
    [ -n "$url" ] && [ -n "$token" ] && printf '%s' "${url%/}"
}

# Called once the tick holds the lock, so every tick that runs pings — including
# NO_WORK ones — and a LOCKED tick does not. Best-effort and time-bounded: it
# never fails the tick. The token goes in via stdin, not argv, so ps can't see it.
pr_review_heartbeat() {
    local url code
    url=$(heartbeat_url) || return 0
    code=$(fu_cfg heartbeat_token | head -n1 | sed 's/^/Authorization: Bearer /' |
        curl -sS -m 5 -o /dev/null -w '%{http_code}' -X POST -H @- \
            "$url/ping/$REPO" 2>/dev/null) || true
    case "$code" in
        2*) log "heartbeat ok (http $code)" ;;
        *)  log "heartbeat FAILED (http ${code:-000})" ;;  # never log the URL or token
    esac
}

fetch_prior_findings() {
    local pr=$1
    gh api "repos/$REPO/pulls/$pr/reviews" 2>/dev/null \
        | jq -r --arg marker "$REVIEW_MARKER" '
            [.[] | select((.body // "") | contains($marker))]
            | sort_by(.submitted_at) | last | .body // ""' 2>/dev/null \
        | sed -e "s|$REVIEW_MARKER||" -e '/^\*Automated review by Claude Code/d' \
              -e "/^<!-- $STATE_TAG:/d" \
        || true
}

# ── Review state on GitHub ─────────────────────────────────────────────────────
# The hidden comment finish appends to every review body:
#   <!-- fu-review-state:<base64 of {"v":1,"commit":…,"tree":…,"carried":{"findings":[…]}}> -->
# `carried` is left out when it would push the body past REVIEW_BODY_MAX; the
# next DELTA then re-checks the posted text instead. state_comment <commit> <tree> [carried]
state_comment() {
    local json
    json=$(jq -cn --arg c "$1" --arg t "$2" --argjson f "${3:-null}" \
        '{v: 1, commit: $c, tree: $t} + (if $f then {carried: $f} else {} end)') || return 1
    printf '<!-- %s:%s -->' "$STATE_TAG" "$(printf '%s' "$json" | base64 | tr -d '\n')"
}

# Our own marked reviews of a PR, one JSON object per line: {submitted_at,
# commit_id, body}. Only the authenticated user's: anyone can post a review
# carrying the marker, and it must not be able to plant state. my_marked_reviews <pr>
my_marked_reviews() {
    local me
    me=$(get_gh_user)
    [ -n "$me" ] || return 1
    gh_api_pages "repos/$REPO/pulls/$1/reviews" \
        ".[] | select(.user.login == \"$me\" and ((.body // \"\") | contains(\"$REVIEW_MARKER\")))
             | {submitted_at, commit_id, body} | @json"
}

# Rebuild the durable `reviewed` and `carried` records from the state comment on
# our latest marked review. Only the latest: an older review's state is stale,
# so a latest review without one restores nothing. Returns 1 when nothing was
# restored. hydrate_from_github <pr>
hydrate_from_github() {
    local pr=$1 latest b64 st commit tree at carried
    latest=$(my_marked_reviews "$pr" 2>/dev/null | jq -sc 'sort_by(.submitted_at) | last // empty')
    [ -n "$latest" ] || return 1
    b64=$(jq -r '.body' <<< "$latest" \
        | sed -nE "s#^<!-- $STATE_TAG:([A-Za-z0-9+/=]+) -->\$#\\1#p" | tail -n 1)
    [ -n "$b64" ] || { log "PR #$pr: our latest review carries no state"; return 1; }
    st=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || return 1
    commit=$(jq -r '.commit // empty' <<< "$st" 2>/dev/null)
    tree=$(jq -r '.tree // empty' <<< "$st" 2>/dev/null)
    at=$(jq -r '.submitted_at // empty' <<< "$latest")
    [ -n "$commit" ] && [ -n "$tree" ] || return 1
    record_write reviewed "$pr" "$commit" "$tree" "$at" || return 1
    carried=$(pr_path carried "$pr")
    if jq -e '.carried.findings | type == "array"' <<< "$st" >/dev/null 2>&1; then
        jq -c '.carried' <<< "$st" > "$carried" 2>/dev/null || rm -f "$carried"
    else
        rm -f "$carried"
    fi
    log "PR #$pr: review state restored from GitHub (commit $commit, reviewed $at)"
}

# Did one of our marked reviews land on <commit> at or after <since> — another
# run, triggered by the same request, posting first? Fails open: no answer means
# post. posted_since <pr> <commit> <since>
posted_since() {
    local pr=$1 commit=$2 since=$3
    [ -n "$since" ] || return 1
    my_marked_reviews "$pr" 2>/dev/null | jq -se --arg c "$commit" --arg s "$since" \
        'any(.[]; .commit_id == $c and .submitted_at >= $s)' >/dev/null 2>&1
}

# Outputs "PR_NUM REASON" lines for PRs that need review.
# REASON is review_requested or review_re_requested.
# Prints nothing for PRs that should be skipped.
detect_queued_prs() {
    local gh_user
    gh_user=$(get_gh_user)
    [ -z "$gh_user" ] && return 1

    local requested_prs
    # A failed later page still queues what the pages before it named.
    requested_prs=$(gh_api_pages "repos/$REPO/pulls?state=open" \
        ".[] | select(any(.requested_reviewers[]?; .login == \"$gh_user\")) | .number" \
        2>/dev/null || true)

    [ -z "$requested_prs" ] && return 0

    while IFS= read -r pr; do
        [ -z "$pr" ] && continue
        local rec
        # A PR that changed no file at its recorded head has nothing to review,
        # whatever its request history, until a push moves its tree.
        if rec=$(record_read empty "$pr"); then
            local head_now
            head_now=$(get_pr_head_info "$pr") || continue
            [ "${head_now##*$'\t'}" = "$(cut -f2 <<< "$rec")" ] && continue
            rm -f "$(pr_path empty "$pr")"
        fi
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
    local listed=1
    open_prs=$(gh_api_pages "repos/$REPO/pulls?state=open" '.[].number' 2>/dev/null) \
        || listed=0
    # File names come from pr_path with a `*` PR, so this knows no names itself.
    # A failed listing would read as "no PR is open" and wipe every review record.
    [ "$listed" = 1 ] || log "WARNING: could not list open PRs — keeping durable state this tick"
    for kind in $DURABLE_KINDS; do
        [ "$listed" = 1 ] || break
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

# The review worktree: a detached checkout of SOURCE_DIR's repository at
# REVIEW_DIR, created on first use. Detached, so it never creates, moves or
# needs a branch, and the session's branches are never touched.
pr_review_ensure_worktree() {
    if [ -e "$REVIEW_DIR/.git" ] &&
       [ "$(git -C "$REVIEW_DIR" rev-parse --show-toplevel 2>/dev/null)" = "$REVIEW_DIR" ]; then
        return 0
    fi
    git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        log "WARNING: $SOURCE_DIR is not a git checkout — no review worktree"
        return 1
    }
    local git_err
    git -C "$SOURCE_DIR" worktree prune >/dev/null 2>&1
    rm -rf "${REVIEW_DIR:?}"
    mkdir -p "$(dirname "$REVIEW_DIR")"
    fetch_main
    git_err=$(git -C "$SOURCE_DIR" worktree add --detach --force "$REVIEW_DIR" origin/main 2>&1) || {
        log "WARNING: could not add the review worktree at $REVIEW_DIR: $git_err"
        return 1
    }
    log "created review worktree $REVIEW_DIR"
}

# Refresh origin/main only. An explicit refspec, so it works whatever fetch
# refspec the session's checkout was given.
fetch_main() {
    local git_err
    git_err=$(git -C "$SOURCE_DIR" fetch --quiet origin \
        '+refs/heads/main:refs/remotes/origin/main' 2>&1) \
        || log "WARNING: 'git fetch origin main' failed in $SOURCE_DIR: $git_err"
}

# Put the review worktree back on a clean, up-to-date origin/main. Called at
# tick start and after each PR, so no PR's files leak into the next review.
pr_review_reset_tree() {
    pr_review_ensure_worktree || return 0
    fetch_main
    local git_err
    git_err=$(git -C "$REVIEW_DIR" checkout -f --detach --quiet origin/main 2>&1) \
        || log "WARNING: 'git checkout -f --detach origin/main' failed in $REVIEW_DIR: $git_err"
    git_err=$(git -C "$REVIEW_DIR" clean -fd --quiet 2>&1) \
        || log "WARNING: 'git clean -fd' failed in $REVIEW_DIR: $git_err"
}

# Detach the review worktree at the PR's head commit, so the sub-agent reads,
# greps and blames the code it reviews. Fetched through refs/pull/<n>/head,
# which also reaches fork PRs. Failing leaves the worktree on main and only
# costs the sub-agent local context: the diff still comes from the API.
# pr_review_checkout_head <pr> <commit>
pr_review_checkout_head() {
    local pr=$1 commit=$2 git_err
    pr_review_ensure_worktree || return 1
    git_err=$(git -C "$REVIEW_DIR" fetch --quiet origin "refs/pull/$pr/head" 2>&1) || {
        log "WARNING: PR #$pr: could not fetch refs/pull/$pr/head: $git_err"
        return 1
    }
    git_err=$(git -C "$REVIEW_DIR" checkout -f --detach --quiet "$commit" 2>&1) || {
        log "WARNING: PR #$pr: could not check out $commit in $REVIEW_DIR: $git_err"
        return 1
    }
    log "PR #$pr: review worktree at $commit"
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
        log "ERROR: could not detect target repo from the origin of $SOURCE_DIR — run the loop from inside a checkout of it, or set PR_REVIEW_REPO"
        log "=== PR review check complete ==="
        pr_review_release_lock
        echo "NO_WORK"
        return 0
    fi
    log "Target repo: $REPO (source: $SOURCE_DIR, review worktree: $REVIEW_DIR)"
    pr_review_heartbeat
    # After the REPO check, so the flag always lands in the right repo's state dir
    # (and an undetected-repo bail writes no flag at all).
    pr_review_set_mode "$@"
    # Create the review worktree on first use, and put it back on a clean main
    # in case a prior tick stopped with it still at a PR's head.
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
# be fetched, and 2 when it is fetched but empty — a PR that changes nothing (an
# empty commit), which a retry would re-SKIP every tick forever. The list goes to
# disk, never stdout (orchestrator context).
write_review_scope() {
    local pr=$1 commit=$2 tree=$3
    local pr_files files="" mode=FULL base="" why="first review" scope_file
    scope_file=$(pr_path scope "$pr")
    rm -f "$scope_file"
    local listing
    listing=$(gh_api_pages "repos/$REPO/pulls/$pr/files" \
        '.[] | [.filename, (.previous_filename // "")] | @tsv' 2>/dev/null) || return 1
    pr_files=$(printf '%s\n' "$listing" | cut -f1 | grep . | LC_ALL=C sort -u)
    [ -z "$pr_files" ] && return 2
    # The approval gate judges the WHOLE PR, never just a DELTA, and a rename's
    # old path too — moving code into docs/ still deletes code.
    tr '\t' '\n' <<< "$listing" | grep . | classify_pr_files > "$(pr_path gate "$pr")"

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
    pr_info=$(gh api "repos/$REPO/pulls/$pr" \
        --jq '{author: {login: .user.login}, state: (.state | ascii_upcase)}' 2>/dev/null || echo '{}')
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

    # No local record (a fresh cloud session, or lost state): take the last
    # review's state from GitHub, so scope and priors work as if it were local.
    record_read reviewed "$pr" >/dev/null || hydrate_from_github "$pr" || true

    local scope_rc=0
    write_review_scope "$pr" "$current_commit" "$current_tree" || scope_rc=$?
    if [ "$scope_rc" -eq 2 ]; then
        # Recorded so detection stops queueing the PR until its tree changes.
        record_write empty "$pr" "$current_commit" "$current_tree"
        log "PR #$pr: changes no files, nothing to review — skipping until its tree changes"
        echo "SKIP"; return 0
    elif [ "$scope_rc" -ne 0 ]; then
        log "PR #$pr: could not fetch the PR's file list, skipping"
        echo "SKIP"; return 0
    fi

    # Pre-write prior findings for the sub-agent. Done here so the sub-agent reads
    # it from disk and never needs gh-pipe permissions of its own.
    write_prior_findings "$pr" 2>/dev/null || true

    # Clear this PR's findings so the sub-agent's run starts clean — stale
    # findings from a prior tick that never reached the post step must not be
    # read by pr_review_finish. Then persist the reviewed commit/tree: the
    # pending record is the PROCEED token pr_review_finish requires.
    rm -f "$(pr_path findings "$pr")"
    record_write pending "$pr" "$current_commit" "$current_tree" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || {
        # No token, no dispatch: finish would drop the finished review as a no-op.
        log "PR #$pr: could not write the pending record, skipping"
        pr_clear "$pr"
        echo "SKIP"; return 0
    }

    pr_review_checkout_head "$pr" "$current_commit" || true

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
    printf '  REVIEW_DIR = %s\n' "$REVIEW_DIR"
}

# Post the sub-agent's review to GitHub, then save state. Takes ONLY the PR number
# — everything else is recovered from disk, so a context compaction landing between
# pre-flight and here loses nothing: commit/tree from pending-<pr> (pre-flight),
# findings from findings-<pr>.json (sub-agent), from which the body, verdict and
# blocker count are derived here. State is saved ONLY on a successful post, so a
# failed post or a missing/invalid findings file retries next tick.
# Prints ONE status token, so the orchestrator can tell the outcomes apart without
# reading the log: POSTED <APPROVE|COMMENT>, FAILED (the POST failed),
# NO_FINDINGS (missing or invalid findings file), NOTHING_PENDING (no PROCEED
# token), or DUPLICATE (another run posted on this head after pre-flight
# dispatched this one). The reason for a non-POSTED outcome stays in the log only.
pr_review_finish() {
    local pr=$1 status

    # pending-<pr> is the PROCEED token: without it no review was dispatched for
    # this head (the orchestrator ran finish after a SKIP, or out of order), so
    # there is nothing to post — and no reviewed commit to record.
    local pend commit tree started
    if ! pend=$(record_read pending "$pr"); then
        log "PR #$pr: nothing pending (pre-flight did not PROCEED) — finish is a no-op"
        pr_clear "$pr"
        pr_review_reset_tree   # still leave the worktree on main for the next PR
        echo "NOTHING_PENDING"
        return 0
    fi
    IFS=$'\t' read -r commit tree started <<< "$pend"

    local findings why
    # A FANOUT review is whole only when every dimension's reviewer left valid
    # findings: a merged file missing one would read clean where nobody looked.
    if mode_has "$pr" fanout && ! why=$(routine_parts_check "$pr"); then
        log "PR #$pr: incomplete FANOUT review ($why) — NOT posting, NOT saving state"
        pr_review_notify nobody "$pr" 0 "" "nothing posted"
        status=NO_FINDINGS
    elif ! findings=$(findings_load "$(pr_path findings "$pr")"); then
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
        if [ "$decision" = "APPROVE" ] && ! auto_approve_enabled "$pr"; then
            log "PR #$pr: no blockers found, but auto-approve is off — posting COMMENT"
            decision="COMMENT"
            downgraded=1
        fi
        # Second gate: only docs/tests/UI-only PRs are approved (see
        # LOW_RISK_PATHS_DEFAULT). A missing gate file fails closed.
        local gate=""
        if [ "$decision" = "APPROVE" ]; then
            gate=$(head -n 1 "$(pr_path gate "$pr")" 2>/dev/null)
            if [ "$gate" != low-risk ]; then
                log "PR #$pr: no blockers found, but not docs/tests/UI only (${gate:-no gate record}) — posting COMMENT"
                decision="COMMENT"
                downgraded=2
            fi
        fi
        review_body=$(findings_body "$pr" <<< "$findings")

        local footer="*Automated review by Claude Code via /code-review*"
        mode_has "$pr" routine && footer="*Automated review by a Claude Code routine*"
        if [ "$downgraded" = 1 ]; then
            footer="$footer
*No blockers found. Posted as a comment, not an approval — auto-approve is off.*"
        elif [ "$downgraded" = 2 ]; then
            footer="$footer
*No blockers found. Posted as a comment, not an approval — only docs, tests and UI changes are auto-approved.*"
        fi
        # No badge on a /review-pr run: it has no loop behind it to keep one live.
        local hb_url
        if ! single_run "$pr" && [ "$(fu_cfg heartbeat_footer | head -n1)" = true ] &&
                hb_url=$(heartbeat_url); then
            footer="$footer

![review bot status]($hb_url/badge/$REPO.svg)"
        fi

        local body carried_json state
        body="$REVIEW_MARKER
$review_body

---
$footer"
        carried_json=$(findings_carried <<< "$findings" 2>/dev/null)
        state=$(state_comment "$commit" "$tree" "${carried_json:-null}")
        if [ $(( ${#body} + 1 + ${#state} )) -gt "$REVIEW_BODY_MAX" ]; then
            log "PR #$pr: carried findings would overflow the review body — state comment holds commit/tree only"
            state=$(state_comment "$commit" "$tree")
        fi
        [ -n "$state" ] && body="$body
$state"

        local submitted_at
        if posted_since "$pr" "$commit" "$started"; then
            # Another run, for the same request, posted on this head while this
            # one reviewed. It also notified and saved state; just tidy up.
            log "PR #$pr: a review of $commit was posted after $started by another run — NOT posting"
            clear_looking_eyes "$pr"
            status=DUPLICATE
        elif submitted_at=$(gh api "repos/$REPO/pulls/$pr/reviews" --method POST \
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
            { [ -n "$carried_json" ] && printf '%s\n' "$carried_json" 2>/dev/null > "$carried"; } || {
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

    # Return the review worktree to a clean main so the next PR's checkout
    # (or the next tick) starts from a pristine tree, not this PR's head.
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

# ── /review-pr: one PR, one run ────────────────────────────────────────────────
# Built for a cloud scheduled task fired by a GitHub pull_request.review_requested
# event: a fresh session per event, so no lock, detection, purge or heartbeat.
# Pre-flight, the sub-agent and finish are the loop's own.

# The open PR whose head is the checkout's HEAD — a PR-triggered cloud session
# starts its clone there. Exactly one, or nothing.
pr_from_head() {
    local sha prs
    sha=$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null) || { log "could not read HEAD of $SOURCE_DIR"; return 1; }
    prs=$(gh api "repos/$REPO/commits/$sha/pulls" \
        --jq ".[] | select(.state == \"open\" and .head.sha == \"$sha\") | .number" 2>/dev/null) \
        || { log "could not list the PRs of HEAD $sha"; return 1; }
    if [ "$(grep -c . <<< "$prs")" != 1 ]; then
        log "HEAD $sha is the head of $(grep -c . <<< "$prs") open PR(s) — need exactly one"
        return 1
    fi
    printf '%s\n' "$prs"
}

# Is the review requested from us by name? A team request does not count:
# repos that auto-add a team would otherwise review every PR.
requested_from_me() {
    local me
    me=$(get_gh_user)
    [ -n "$me" ] || return 1
    gh api "repos/$REPO/pulls/$1" \
        --jq "any(.requested_reviewers[]?; .login == \"$me\")" 2>/dev/null | grep -qx true
}

# A /review-pr SKIP carries its reason on the same line — the last thing logged,
# which every skip path writes just before it. A cloud run's log file dies with
# its sandbox, so this line is the only record of why it skipped.
one_skip() {
    printf 'SKIP — %s\n' "$(tail -n 1 "$LOG_FILE" 2>/dev/null | sed 's/^\[[^]]*\] //')"
}

# Review one PR. Arguments: a PR as `123`, `#123` or a PR URL (whose repo then
# overrides the checkout's), `--auto-approve`, and `--routine`; no PR means the
# one whose head is HEAD. Outputs "SKIP — <reason>", or "PROCEED <pr> <owner/name>" followed
# by the Task prompt — with --routine, "SINGLE|FANOUT <pr> <owner/name>" followed
# by the agent blocks (routine_prompts). The mode goes to disk per PR (`mode`),
# never the loop's tick-wide flag.
pr_review_one() {
    local a pr="" url_repo="" approve=0 routine=0
    for a in "$@"; do
        case "$a" in
            "") ;;
            --auto-approve|--approve) approve=1 ;;
            --routine) routine=1 ;;
            https://github.com/*/pull/*)
                url_repo=$(sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+.*#\1#p' <<< "$a")
                pr=$(sed -nE 's#^https://github\.com/[^/]+/[^/]+/pull/([0-9]+).*#\1#p' <<< "$a") ;;
            *)
                if [[ "$a" =~ ^#?([0-9]+)$ ]]; then pr=${BASH_REMATCH[1]}
                else log "WARNING: ignoring unrecognised argument '$a'"; fi ;;
        esac
    done
    [ "${PR_REVIEW_AUTO_APPROVE:-0}" = 1 ] && approve=1
    if [ -n "$url_repo" ] && [ "$url_repo" != "$REPO" ]; then
        # Every path derives from REPO at source time.
        export PR_REVIEW_REPO=$url_repo
        source "$LIB_DIR/lib.sh"
    fi

    rotate_log "$LOG_FILE"
    log "=== /review-pr ${pr:-(PR from HEAD)} ==="
    if [ -z "$REPO" ]; then
        log "ERROR: could not detect the target repo — pass a PR URL, or set PR_REVIEW_REPO"
        one_skip; return 0
    fi
    if [ -z "$pr" ] && ! pr=$(pr_from_head); then
        one_skip; return 0
    fi
    if ! requested_from_me "$pr"; then
        log "PR #$pr: review not requested from $(get_gh_user) by name"
        one_skip; return 0
    fi

    { echo single; [ "$approve" = 1 ] && echo auto-approve; [ "$routine" = 1 ] && echo routine; } \
        > "$(pr_path mode "$pr")"
    log "PR #$pr: auto-approve $([ "$approve" = 1 ] && echo ENABLED || echo off)"
    pr_review_reset_tree

    local out
    out=$(pr_review_preflight "$pr" review_requested)
    if [ "$(head -n 1 <<< "$out")" != PROCEED ]; then
        pr_clear "$pr"
        one_skip; return 0
    fi
    if [ "$routine" = 1 ]; then
        routine_prompts "$pr"
        return 0
    fi
    printf 'PROCEED %s %s\n' "$pr" "$REPO"
    tail -n +2 <<< "$out"
}

# ── The review routine: /review-pr's flow with a self-contained review ─────────
# A cloud routine loads no plugin, so neither /code-review nor review-task.md's
# flow is available to it. pr_review_one --routine runs the same guard and
# pre-flight, then prints prompts for briefs that carry their own review method
# (routine-reviewer.md, routine-merger.md). A small scope gets one reviewer that
# covers every dimension (SINGLE); anything larger gets one reviewer per
# dimension plus a merger (FANOUT). The orchestrator only copies the blocks.
ROUTINE_DIMENSIONS="correctness security intent"
ROUTINE_SINGLE_MAX_FILES=5
ROUTINE_SINGLE_MAX_LINES=200
ROUTINE_REVIEWER_BRIEF="$(dirname "$REVIEW_TASK_FILE")/routine-reviewer.md"
ROUTINE_MERGER_BRIEF="$(dirname "$REVIEW_TASK_FILE")/routine-merger.md"

# Print "<files> <lines>" for the review scope: the files in scope-<pr>.txt and
# their changed lines (additions + deletions, whole-PR per file, so a DELTA is
# over-counted — toward FANOUT, the safe side). An unfetchable count prints a
# line total past the threshold. routine_scope_size <pr>
routine_scope_size() {
    local pr=$1 files n lines
    files=$(sed '1,/^$/d' "$(pr_path scope "$pr")" 2>/dev/null | grep .)
    n=$(grep -c . <<< "$files")
    if ! lines=$(gh_api_pages "repos/$REPO/pulls/$pr/files" \
            '.[] | [.filename, ((.additions // 0) + (.deletions // 0))] | @tsv' 2>/dev/null); then
        printf '%s %s\n' "$n" $((ROUTINE_SINGLE_MAX_LINES + 1)); return 0
    fi
    lines=$(awk -F'\t' 'NR == FNR { want[$0] = 1; next } ($1 in want) { s += $2 } END { print s + 0 }' \
        <(printf '%s\n' "$files") <(printf '%s\n' "$lines"))
    printf '%s %s\n' "$n" "$lines"
}

# One reviewer's block. routine_reviewer_block <pr> <dimension> <output-file>
routine_reviewer_block() {
    local pr=$1 dim=$2 out=$3
    printf -- '--- reviewer %s ---\n' "$dim"
    printf 'Read %s and follow it exactly. Review PR #%s, dimension: %s.\n' \
        "$ROUTINE_REVIEWER_BRIEF" "$pr" "$dim"
    printf 'Use these absolute paths verbatim — do not construct your own:\n'
    printf '  SCOPE_FILE = %s\n' "$(pr_path scope "$pr")"
    if [ "$dim" = all ]; then printf '  PRIOR_FILE = %s\n' "$(pr_path prior "$pr")"; fi
    printf '  OUTPUT_FILE = %s\n' "$out"
    printf '  REVIEW_DIR = %s\n' "$REVIEW_DIR"
}

# After a PROCEEDing pre-flight: pick SINGLE or FANOUT from the scope's size,
# record it in the mode, and print the token line, then one block per agent —
# "--- reviewer <dimension> ---" blocks, dispatched together, and for FANOUT a
# "--- merger ---" block, dispatched after them. routine_prompts <pr>
routine_prompts() {
    local pr=$1 size n lines d
    size=$(routine_scope_size "$pr")
    n=${size% *} lines=${size#* }
    if [ "$n" -le "$ROUTINE_SINGLE_MAX_FILES" ] && [ "$lines" -le "$ROUTINE_SINGLE_MAX_LINES" ]; then
        log "PR #$pr: SINGLE review ($n file(s), $lines line(s))"
        printf 'SINGLE %s %s\n' "$pr" "$REPO"
        routine_reviewer_block "$pr" all "$(pr_path findings "$pr")"
        return 0
    fi
    log "PR #$pr: FANOUT review ($n file(s), $lines line(s))"
    echo fanout >> "$(pr_path mode "$pr")"
    printf 'FANOUT %s %s\n' "$pr" "$REPO"
    for d in $ROUTINE_DIMENSIONS; do
        routine_reviewer_block "$pr" "$d" "$(pr_path "part_$d" "$pr")"
    done
    printf -- '--- merger ---\n'
    printf 'Read %s and follow it exactly. Merge the reviews of PR #%s.\n' "$ROUTINE_MERGER_BRIEF" "$pr"
    printf 'Use these absolute paths verbatim — do not construct your own:\n'
    printf '  SCOPE_FILE = %s\n' "$(pr_path scope "$pr")"
    printf '  PRIOR_FILE = %s\n' "$(pr_path prior "$pr")"
    for d in $ROUTINE_DIMENSIONS; do
        printf '  PART_FILE_%s = %s\n' "$(tr '[:lower:]' '[:upper:]' <<< "$d")" "$(pr_path "part_$d" "$pr")"
    done
    printf '  FINDINGS_FILE = %s\n' "$(pr_path findings "$pr")"
    printf '  REVIEW_DIR = %s\n' "$REVIEW_DIR"
}

# Every dimension's part file loads (findings_load). Prints why not and returns 1.
# routine_parts_check <pr>
routine_parts_check() {
    local pr=$1 d why
    for d in $ROUTINE_DIMENSIONS; do
        why=$(findings_load "$(pr_path "part_$d" "$pr")") || { printf '%s: %s' "$d" "$why"; return 1; }
    done
}
