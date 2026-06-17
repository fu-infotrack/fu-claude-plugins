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
# Locate review-task.md (ships beside this script in the plugin). Prefer the
# plugin root the command exports; fall back to this script's own dir.
if [ -n "${REVIEW_TASK_FILE:-}" ]; then
    :
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/review-task.md" ]; then
    REVIEW_TASK_FILE="$CLAUDE_PLUGIN_ROOT/review-task.md"
else
    LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    REVIEW_TASK_FILE="$(cd "$LIB_DIR/.." && pwd)/review-task.md"
fi
# Namespace lock/state/log per repo so concurrent loops on different remotes
# don't contend on one lock, and PR-number-keyed state files don't collide
# across repos (e.g. owner-a/repo PR #5 vs owner-b/repo PR #5).
REPO_SLUG="$(printf '%s' "${REPO:-unknown}" | tr '/' '-')"
STATE_DIR="$BASE_DIR/state/$REPO_SLUG"
LOG_FILE="$BASE_DIR/review-$REPO_SLUG.log"
LOCK_FILE="$BASE_DIR/review-prs-$REPO_SLUG.lock"
HOLDER_FILE="$BASE_DIR/review-prs-$REPO_SLUG.lock.holder"
MAX_LOG_BYTES=128000

mkdir -p "$STATE_DIR"

# Print this PR's namespaced state paths, for the orchestrator to inject into
# the review sub-agent's prompt (the sub-agent must not derive its own).
pr_review_paths() {
    local pr=$1
    printf 'STATE_FILE=%s\nPRIOR_FILE=%s\nBODY_FILE=%s\n' \
        "$STATE_DIR/last-reviewed-$pr" \
        "$STATE_DIR/prior-$pr.txt" \
        "$STATE_DIR/review-body-$pr.md"
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
    find "$STATE_DIR" -maxdepth 1 \( -name "codeql-wait-*" -o -name "copilot-wait-*" -o -name "prior-*.txt" -o -name "review-body-*.md" \) -delete 2>/dev/null || true
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
}

# Acquire lock, setup, purge stale files, detect queued PRs.
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
        pr_review_release_lock
        echo "NO_WORK"
    else
        printf '%s\n' "$queued"
    fi
}

# Pre-flight check for a single PR. Outputs "SKIP" or a tab-separated PROCEED line.
# Fields: PROCEED <current_commit> <current_tree>
# The sub-agent derives review mode (first/delta) and delta_base itself from the
# state file; this function only decides whether the sub-agent should run at all,
# and pre-writes the prior-findings file the sub-agent reads in delta mode.
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

    printf 'PROCEED\t%s\t%s\n' "$current_commit" "$current_tree"
}

# Post the sub-agent's review body to GitHub, then save state.
# The sub-agent writes the body to state/review-body-<pr>.md; this function
# wraps it with the marker + footer and posts a formal GitHub Review.
# State is saved ONLY on a successful post, so a failed/empty review retries.
pr_review_finish() {
    local pr=$1 commit=$2 tree=$3 decision=$4
    local body_file="$STATE_DIR/review-body-${pr}.md"

    if [ ! -s "$body_file" ]; then
        log "PR #$pr: no review body produced — NOT posting, NOT saving state (will retry next tick)"
    else
        local body
        body="$REVIEW_MARKER
$(cat "$body_file")

---
*Automated review by Claude Code via /code-review*"

        if gh api "repos/$REPO/pulls/$pr/reviews" --method POST \
                -f "event=$decision" -f "body=$body" >/dev/null 2>&1; then
            log "PR #$pr: posted $decision review"
            save_review_state "$pr" "$commit" "$tree"
        else
            log "PR #$pr: FAILED to post review — NOT saving state (will retry next tick)"
        fi
        rm -f "$body_file"
    fi

    # Return the dedicated clone to a clean main so the next PR's sub-agent
    # (or the next tick) starts from a pristine tree, not this PR's branch.
    pr_review_reset_tree
}

# End-of-run: log completion and release the lock. Stale-file purge already
# happened in pr_review_init. Only reached on the work path (NO_WORK releases
# in init). If the agent skips this, the 7200s holder timeout releases the lock.
pr_review_cleanup() {
    log "=== PR review check complete ==="
    pr_review_release_lock
}
