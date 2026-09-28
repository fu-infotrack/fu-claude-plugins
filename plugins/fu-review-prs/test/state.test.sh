#!/usr/bin/env bash
# Tests for the per-PR state store in scripts/lib.sh — pr_path, the record_* pair,
# and the callers that depend on them: pr_review_finish (pending = PROCEED token,
# reviewed_at from GitHub, transients cleared), detect_queued_prs (re-request vs
# reviewed_at) and pr_review_purge_stale. No framework — run:
#   bash plugins/fu-review-prs/test/state.test.sh
#
# Hermetic: a throwaway HOME holds the state dir, and `gh`/`git` are stubbed on
# PATH, so nothing here touches the real ~/.claude/pr-review or hits GitHub.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/lib.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

eq() { # eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1
    expected: <$2>
    actual:   <$3>"; fi
}
has() { if grep -qF -- "$2" <<<"$3"; then ok; else bad "$1 (missing <$2>)"; fi; }

SANDBOX=""
new_sandbox() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$SANDBOX/bin"
  export GH_POST="$SANDBOX/gh-post.txt"
  # gh stub. The real gh applies --jq itself, so the stub answers post-jq values.
  #   SUBMITTED_AT — submitted_at in the review POST's response ("" = omitted)
  #   OPEN_PRS     — `pr list` answer (open PRs, and the review-requested ones)
  #   REREQ_AT     — created_at of our latest review_requested event
  cat >"$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/widgets"; exit 0 ;;
  "api user")  echo "bot"; exit 0 ;;
  "pr list")   printf '%s\n' "${OPEN_PRS-7}"; exit 0 ;;
esac
if [ "$1" = "api" ] && [[ "$2" == *"/pulls/"*"/reviews" ]]; then
  if [[ "$*" == *"--method POST"* ]]; then
    printf '%s\n' "$@" > "$GH_POST"
    # post-jq (`.submitted_at // empty`): the timestamp, or nothing
    printf '%s' "${SUBMITTED_AT-2026-09-28T10:00:00Z}"
  else
    echo '[]'
  fi
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" == *"/events"* ]]; then
  if [ -n "${REREQ_AT:-}" ]; then
    printf '[{"event":"review_requested","requested_reviewer":{"login":"bot"},"created_at":"%s"}]\n' "$REREQ_AT"
  else
    echo '[]'
  fi
  exit 0
fi
exit 0
STUB
  cat >"$SANDBOX/bin/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--is-inside-work-tree" ] && exit 1; done
for a in "$@"; do [ "$a" = "rev-parse" ] && { echo "/nonexistent/review-clone"; exit 0; }; done
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/git"
  export PATH="$SANDBOX/bin:$PATH"
  unset SUBMITTED_AT OPEN_PRS REREQ_AT PR_REVIEW_AUTO_APPROVE
  STATE="$HOME/.claude/pr-review/state/acme-widgets"
  LOG="$HOME/.claude/pr-review/review-acme-widgets.log"
}
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Source lib.sh in a fresh shell (it computes its paths at source time) and run a
# snippet; cwd is the sandbox so fu-config.sh resolves no project config.
# lib <shell-snippet>
lib() { ( cd "$SANDBOX" && bash -c 'source "$1"; eval "$2"' _ "$LIB" "$1" ) 2>/dev/null; }

echo "== a written record reads back as commit, tree, reviewed_at =="
new_sandbox
eq "round trip" $'c0mm1t\ttr33\t2026-09-28T10:00:00Z' \
  "$(lib 'record_write reviewed 7 c0mm1t tr33 2026-09-28T10:00:00Z; record_read reviewed 7')"
eq "on disk it is key=value" $'commit=c0mm1t\ntree=tr33\nreviewed_at=2026-09-28T10:00:00Z' \
  "$(cat "$STATE/last-reviewed-7")"
cleanup

echo "== a legacy two-line record reads, reviewed_at from its mtime =="
new_sandbox
mkdir -p "$STATE"
printf 'c0mm1t\ntr33\n' > "$STATE/last-reviewed-7"
touch -d '2026-01-02T03:04:05Z' "$STATE/last-reviewed-7"
eq "legacy read" $'c0mm1t\ttr33\t2026-01-02T03:04:05Z' "$(lib 'record_read reviewed 7')"
cleanup

echo "== an absent or incomplete record is not a record =="
new_sandbox
eq "absent" "1" "$(lib 'record_read reviewed 7; echo $?')"
mkdir -p "$STATE"; printf 'commit=c0mm1t\n' > "$STATE/pending-7"
eq "no tree" "1" "$(lib 'record_read pending 7; echo $?')"
cleanup

echo "== finish without a pending record is a no-op (pre-flight never PROCEEDed) =="
new_sandbox
lib 'echo "{\"findings\":[]}" > "$(pr_path findings 7)"; pr_review_finish 7'
eq "nothing posted" "absent" "$([ -e "$GH_POST" ] && echo present || echo absent)"
eq "no state saved" "absent" "$([ -e "$STATE/last-reviewed-7" ] && echo present || echo absent)"
has "logged as an ordering error" "PR #7: nothing pending" "$(cat "$LOG")"
cleanup

echo "== finish after a SKIP (no pending, no findings) raises no 'no findings' alarm =="
new_sandbox
lib 'pr_review_finish 7'
eq "no missing-findings path taken" "0" "$(grep -c 'no usable findings' "$LOG")"
cleanup

# Seed one dispatched PR — pending + every transient + findings — then finish it.
finish_dispatched() {
  lib 'record_write pending 7 deadbeef cafef00d
       for k in scope prior; do echo x > "$(pr_path $k 7)"; done
       echo "{\"findings\":[]}" > "$(pr_path findings 7)"
       pr_review_finish 7'
}

echo "== a posted review records GitHub's submitted_at =="
new_sandbox
finish_dispatched
eq "reviewed record" $'deadbeef\tcafef00d\t2026-09-28T10:00:00Z' "$(lib 'record_read reviewed 7')"
eq "every transient cleared, the durable pair kept" $'last-findings-7.json\nlast-reviewed-7' "$(ls "$STATE")"
cleanup

echo "== no submitted_at in the response: reviewed_at is local UTC now =="
new_sandbox
SUBMITTED_AT="" finish_dispatched
at=$(lib 'record_read reviewed 7' | cut -f3)
has "ISO-8601 UTC" "Z" "$at"
eq "recent" "ok" "$([ $(( $(date -u +%s) - $(date -u -d "$at" +%s 2>/dev/null || echo 0) )) -lt 60 ] && echo ok)"
cleanup

echo "== detection: a re-request after reviewed_at queues the PR =="
new_sandbox
lib 'record_write reviewed 7 c0mm1t tr33 2026-09-28T10:00:00Z'
touch -d '2026-09-28T12:00:00Z' "$STATE/last-reviewed-7"   # mtime must not decide
eq "queued" "7 review_re_requested" "$(REREQ_AT=2026-09-28T11:00:00Z lib 'detect_queued_prs')"
cleanup

echo "== detection: a re-request before reviewed_at does not =="
new_sandbox
lib 'record_write reviewed 7 c0mm1t tr33 2026-09-28T10:00:00Z'
touch -d '2026-09-28T08:00:00Z' "$STATE/last-reviewed-7"
eq "not queued" "" "$(REREQ_AT=2026-09-28T09:00:00Z lib 'detect_queued_prs')"
cleanup

echo "== detection: a legacy record still compares by mtime =="
new_sandbox
mkdir -p "$STATE"; printf 'c0mm1t\ntr33\n' > "$STATE/last-reviewed-7"
touch -d '2026-09-28T10:00:00Z' "$STATE/last-reviewed-7"
eq "queued" "7 review_re_requested" "$(REREQ_AT=2026-09-28T11:00:00Z lib 'detect_queued_prs')"
cleanup

echo "== purge: closed PRs' records and every PR's transients go, the rest stays =="
new_sandbox
lib 'record_write reviewed 7 a b; record_write reviewed 8 c d
     for k in pending scope prior findings; do echo x > "$(pr_path $k 8)"; done
     for f in review-body-8.md decision-8.txt prior-8.txt; do echo x > "$STATE_DIR/$f"; done   # pre-v0.7.0
     : > "$AUTO_APPROVE_FILE"'
OPEN_PRS=8 lib 'pr_review_purge_stale'
eq "kept: open PR's record, tick flag" $'auto-approve\nlast-reviewed-8' "$(ls "$STATE")"
cleanup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
