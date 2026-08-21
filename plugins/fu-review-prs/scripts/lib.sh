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
# step reads it back the same way it reads the decision — a mid-tick compaction
# can never flip a COMMENT tick into an approving one.
AUTO_APPROVE_FILE="$STATE_DIR/auto-approve"
LOG_FILE="$BASE_DIR/review-$REPO_SLUG.log"
LOCK_FILE="$BASE_DIR/review-prs-$REPO_SLUG.lock"
HOLDER_FILE="$BASE_DIR/review-prs-$REPO_SLUG.lock.holder"
MAX_LOG_BYTES=128000

mkdir -p "$STATE_DIR"

# Print this PR's namespaced state paths, for the orchestrator to inject into
# the review sub-agent's prompt (the sub-agent must not derive its own).
pr_review_paths() {
    local pr=$1
    printf 'STATE_FILE=%s\nPRIOR_FILE=%s\nBODY_FILE=%s\nDECISION_FILE=%s\n' \
        "$STATE_DIR/last-reviewed-$pr" \
        "$STATE_DIR/prior-$pr.txt" \
        "$STATE_DIR/review-body-$pr.md" \
        "$STATE_DIR/decision-$pr.txt"
}

rotate_log() {
    local file=$1
    if [ -f "$file" ] && [ "$(stat -c%s "$file" 2>/dev/null || echo 0)" -ge "$MAX_LOG_BYTES" ]; then
        mv -f "$file" "${file}.old"
    fi
}

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$line" >> "$LOG_FILE"
    printf '%s\n' "$line" >&2
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

save_review_state() {
    local pr=$1 commit=$2 tree=$3
    printf '%s\n%s\n' "$commit" "$tree" > "$STATE_DIR/last-reviewed-${pr}"
}

read_review_state() {
    local pr=$1
    local state_file="$STATE_DIR/last-reviewed-${pr}"
    [ -f "$state_file" ] || return 1
    local commit tree
    { read -r commit; read -r tree; } < "$state_file"
    [ -z "$commit" ] && return 1
    [ -z "$tree" ] && return 1
    printf '%s\t%s\n' "$commit" "$tree"
}

# pending-<pr>: the commit/tree being reviewed, persisted by pre-flight so the
# post step recovers them from DISK rather than from the orchestrator's context.
# This makes the pre-flight -> post handoff immune to a context compaction that
# lands mid-tick (right after the sub-agent returns). Same two-line shape as the
# state file. Written only on the PROCEED path; cleared by pr_review_finish.
write_pending() {
    local pr=$1 commit=$2 tree=$3
    printf '%s\n%s\n' "$commit" "$tree" > "$STATE_DIR/pending-${pr}"
}

read_pending() {
    local pr=$1
    local f="$STATE_DIR/pending-${pr}"
    [ -f "$f" ] || return 1
    local commit tree
    { read -r commit; read -r tree; } < "$f"
    [ -z "$commit" ] && return 1
    [ -z "$tree" ] && return 1
    printf '%s\t%s\n' "$commit" "$tree"
}

# Resolve the sub-agent's decision from DISK, never from the orchestrator's
# context: the decision-<pr>.txt sidecar first (clean single token), else the
# "<!-- DECISION: X -->" header the sub-agent also writes as the body's first
# line, else COMMENT (conservative — never auto-approve on ambiguity).
read_decision() {
    local pr=$1 body_file=$2 d=""
    local sidecar="$STATE_DIR/decision-${pr}.txt"
    if [ -s "$sidecar" ]; then
        d=$(tr -d ' \t\r\n' < "$sidecar" | tr '[:lower:]' '[:upper:]')
    fi
    if [ "$d" != "APPROVE" ] && [ "$d" != "COMMENT" ] && [ -f "$body_file" ]; then
        d=$(sed -n '1{/<!-- *DECISION:/p};q' "$body_file" \
            | sed -E 's/.*DECISION:[[:space:]]*([A-Za-z]+).*/\1/' | tr '[:lower:]' '[:upper:]')
    fi
    case "$d" in APPROVE|COMMENT) printf '%s' "$d" ;; *) printf 'COMMENT' ;; esac
}

# How many CURRENT blockers a review body reports. Counting raw "[BLOCKER]"
# occurrences is wrong in DELTA mode: review-task.md's "Prior findings:" block
# re-prints each prior finding's ORIGINAL severity tag alongside its new status,
# so a fixed blocker still carries the literal tag. Measured on EntityPlatform
# #2172 — a lone RESOLVED prior blocker was notified as "1 blocker(s)" while the
# body it linked to said "No blockers found".
#
# So drop a line only when RESOLVED appears BEFORE the tag, i.e. in the status
# position the prior-findings block puts it in. STILL OPEN and REINTRODUCED lines
# still count (Step 3 treats them as current blockers), and the word "resolved"
# inside a live finding's own description is prose, not a status.
count_blockers() { # count_blockers <body-file>
    [ -f "$1" ] || { printf '0'; return 0; }
    grep '\[BLOCKER\]' "$1" 2>/dev/null | grep -cv 'RESOLVED.*\[BLOCKER\]' || true
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
        local state_file="$STATE_DIR/last-reviewed-${pr}"

        # Case A: never reviewed (or state file lost)
        if [ ! -f "$state_file" ]; then
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

        local state_mtime_iso
        state_mtime_iso=$(date -u -r "$state_file" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
        [ -z "$state_mtime_iso" ] && continue

        if [[ "$last_req_ts" > "$state_mtime_iso" ]]; then
            log "PR #$pr: re-requested at $last_req_ts (state mtime $state_mtime_iso) — queueing"
            echo "$pr review_re_requested"
        fi
    done <<< "$requested_prs"
}

# Remove stale temp files and state files for closed PRs. Safe to call anytime.
pr_review_purge_stale() {
    local open_prs
    open_prs=$(gh pr list --repo "$REPO" --state open --json number --jq '.[].number' 2>/dev/null || true)
    while IFS= read -r state_file; do
        local pr_num
        pr_num=$(basename "$state_file" | sed -E 's/last-reviewed-//')
        echo "$open_prs" | grep -qw "$pr_num" || rm -f "$state_file"
    done < <(find "$STATE_DIR" -maxdepth 1 -name "last-reviewed-*" 2>/dev/null)
    find "$STATE_DIR" -maxdepth 1 \( -name "codeql-wait-*" -o -name "copilot-wait-*" -o -name "prior-*.txt" -o -name "review-body-*.md" -o -name "pending-*" -o -name "decision-*.txt" \) -delete 2>/dev/null || true
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

# Pre-flight check for a single PR. Outputs "SKIP" or a bare "PROCEED" line.
# On PROCEED it persists the reviewed commit/tree to pending-<pr> on disk, so the
# orchestrator no longer needs to carry them in context to the post step (Step 2c)
# — the handoff survives a mid-tick compaction. The sub-agent derives review mode
# (first/delta) and delta_base itself from the state file; this function only
# decides whether the sub-agent should run at all, and pre-writes the
# prior-findings file the sub-agent reads in delta mode.
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

    react_looking_eyes "$pr"

    local head_info current_commit current_tree
    head_info=$(get_pr_head_info "$pr") || {
        log "PR #$pr: could not fetch head info, skipping"
        echo "SKIP"; return 0
    }
    current_commit=${head_info%%$'\t'*}
    current_tree=${head_info##*$'\t'}

    local state
    if state=$(read_review_state "$pr"); then
        local last_tree
        last_tree=${state##*$'\t'}

        if [ "$last_tree" = "$current_tree" ] && [ "$reason" != "review_re_requested" ]; then
            log "PR #$pr: tree SHA unchanged, skipping (refreshing commit SHA)"
            save_review_state "$pr" "$current_commit" "$current_tree"
            echo "SKIP"; return 0
        fi

        if [ "$last_tree" != "$current_tree" ]; then
            log "PR #$pr: delta review (tree changed)"
        else
            log "PR #$pr: re-request, tree unchanged — full re-review"
        fi
    else
        log "PR #$pr: first review"
    fi

    # Pre-write prior findings for the sub-agent (empty if none). Done here so the
    # sub-agent reads it from disk and never needs gh-pipe permissions of its own.
    fetch_prior_findings "$pr" > "$STATE_DIR/prior-${pr}.txt" 2>/dev/null || true

    # Clear this PR's transient outputs so the sub-agent's run starts clean — a
    # stale body/decision from a prior tick that never reached the post step must
    # not be read by pr_review_finish. Then persist the reviewed commit/tree.
    rm -f "$STATE_DIR/review-body-${pr}.md" "$STATE_DIR/decision-${pr}.txt"
    write_pending "$pr" "$current_commit" "$current_tree"

    printf 'PROCEED\n'
}

# Post the sub-agent's review to GitHub, then save state. Takes ONLY the PR number
# — everything else is recovered from disk, so a context compaction landing between
# pre-flight and here loses nothing: commit/tree from pending-<pr> (pre-flight),
# decision from the decision-<pr>.txt sidecar / body header (sub-agent), body from
# review-body-<pr>.md (sub-agent). State is saved ONLY on a successful post, so a
# failed/empty review retries next tick.
pr_review_finish() {
    local pr=$1
    local body_file="$STATE_DIR/review-body-${pr}.md"
    local pending_file="$STATE_DIR/pending-${pr}"
    local decision_file="$STATE_DIR/decision-${pr}.txt"

    if [ ! -s "$body_file" ]; then
        log "PR #$pr: no review body produced — NOT posting, NOT saving state (will retry next tick)"
        pr_review_notify nobody "$pr" 0 "" "nothing posted, retries next tick"
    else
        # commit/tree from disk; re-derive from the live head only if pending is
        # missing (anomaly) — logged, since that risks recording a newer commit.
        local commit="" tree="" pend
        if pend=$(read_pending "$pr"); then
            commit=${pend%%$'\t'*}; tree=${pend##*$'\t'}
        else
            log "PR #$pr: pending file missing — re-deriving head (may record a newer commit than reviewed)"
            local hi
            hi=$(get_pr_head_info "$pr") && { commit=${hi%%$'\t'*}; tree=${hi##*$'\t'}; }
        fi

        local decision agent_decision review_body downgraded=0
        decision=$(read_decision "$pr" "$body_file")
        # Keep the sub-agent's own verdict: the downgrade below overwrites
        # $decision, but "did the sub-agent find zero blockers" is what the
        # blocker count is cross-checked against.
        agent_decision=$decision
        # Policy gate: the sub-agent's APPROVE only means "zero BLOCKERs". Turning
        # that into a posted GitHub approval needs the opt-in flag (see
        # AUTO_APPROVE_FILE); without it the same findings post as a COMMENT.
        if [ "$decision" = "APPROVE" ] && ! auto_approve_enabled; then
            log "PR #$pr: no blockers found, but auto-approve is off — posting COMMENT"
            decision="COMMENT"
            downgraded=1
        fi
        # Drop a leading "<!-- DECISION: X -->" header line so the posted body is clean.
        review_body=$(sed '1{/^<!-- *DECISION:/d}' "$body_file")

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

        # Blocker count comes from the body the sub-agent wrote — it is the one
        # number worth pushing to a phone, and it needs no extra API call.
        local blockers count_note=""
        blockers=$(count_blockers "$body_file")
        # The decision wins on disagreement. APPROVE means exactly "zero
        # BLOCKERs" (see the policy gate above), so a tag the count picked up out
        # of prose must not contradict it — a notification saying "1 blocker(s)"
        # over a body saying "No blockers found" is the worst kind of false
        # positive for something meant to be triaged from a toast.
        #
        # But the disagreement is itself news, so it rides along as $detail
        # instead of vanishing: a sub-agent that wrote real blockers into the body
        # and APPROVE into the sidecar must not produce a serene "no blockers"
        # toast. Logging it is not enough — the log is what the notifier exists to
        # avoid reading.
        if [ "$agent_decision" = "APPROVE" ] && [ "$blockers" != 0 ]; then
            count_note="decision APPROVE despite $blockers [BLOCKER] tag(s) in the body"
            log "PR #$pr: $count_note — reporting 0"
            blockers=0
        fi

        if gh api "repos/$REPO/pulls/$pr/reviews" --method POST \
                -f "event=$decision" -f "body=$body" >/dev/null 2>&1; then
            log "PR #$pr: posted $decision review"
            if [ -n "$commit" ] && [ -n "$tree" ]; then
                save_review_state "$pr" "$commit" "$tree"
            else
                log "PR #$pr: posted but commit/tree unresolved — state NOT saved (will re-review next tick)"
            fi
            if [ "$blockers" -gt 0 ] 2>/dev/null; then
                pr_review_notify blockers "$pr" "$blockers" "$decision" ""
            else
                pr_review_notify clean "$pr" 0 "$decision" "$count_note"
            fi
        else
            log "PR #$pr: FAILED to post review — NOT saving state (will retry next tick)"
            pr_review_notify failed "$pr" "$blockers" "$decision" "retries next tick"
        fi
    fi
    # Always clear this PR's transients; the next tick regenerates them.
    rm -f "$body_file" "$pending_file" "$decision_file"

    # Return the dedicated clone to a clean main so the next PR's sub-agent
    # (or the next tick) starts from a pristine tree, not this PR's branch.
    pr_review_reset_tree
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
