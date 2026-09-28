#!/usr/bin/env bash
# Tests for pr_review_preflight's stdout contract in scripts/lib.sh — the whole of
# what reaches the orchestrator's context: `SKIP`, or `PROCEED` followed by the
# ready-to-pass Task prompt, and never a log line on stderr. No framework — run:
#   bash plugins/fu-review-prs/test/preflight.test.sh
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

SANDBOX=""
new_sandbox() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$SANDBOX/bin"
  # gh stub. The real gh applies --jq itself, so the stub answers post-jq values.
  #   PR_STATE   — the PR's state (default OPEN); "none" makes the info fetch fail
  #   HEAD_FAIL  — non-empty makes the head-commit lookup fail
  cat >"$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/widgets"; exit 0 ;;
  "pr view")
    if [[ "$*" == *"author,state"* ]]; then
      [ "${PR_STATE:-OPEN}" = "none" ] && exit 1
      printf '{"author":{"login":"alice"},"state":"%s"}\n' "${PR_STATE:-OPEN}"
    else
      [ -n "${HEAD_FAIL:-}" ] && exit 1
      echo "deadbeef"
    fi
    exit 0 ;;
esac
if [ "$1" = "api" ] && [[ "$2" == *"/commits/"* ]]; then echo "cafef00d"; exit 0; fi
if [ "$1" = "api" ] && [[ "$2" == *"/reviews" ]]; then echo "[]"; exit 0; fi
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
  # Let lib.sh resolve review-task.md beside itself, not from an installed plugin.
  unset PR_STATE HEAD_FAIL CLAUDE_PLUGIN_ROOT REVIEW_TASK_FILE
}
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Run pre-flight in a fresh shell (lib.sh computes its paths at source time),
# stdout and stderr captured to separate files. preflight <pr> <reason>
preflight() {
  bash -c 'source "$1"; pr_review_preflight "$2" "$3"' _ "$LIB" "$1" "$2" \
    > "$SANDBOX/out" 2> "$SANDBOX/err"
}
out() { cat "$SANDBOX/out"; }
err() { cat "$SANDBOX/err"; }

echo "== PROCEED is followed by the ready Task prompt =="
new_sandbox
STATE="$HOME/.claude/pr-review/state/acme-widgets"
preflight 7 review_requested
expected="PROCEED
Read $ROOT/review-task.md and follow it exactly. Review PR #7.
Use these absolute paths verbatim — do not construct your own:
  STATE_FILE = $STATE/last-reviewed-7
  PRIOR_FILE = $STATE/prior-7.txt
  BODY_FILE = $STATE/review-body-7.md
  DECISION_FILE = $STATE/decision-7.txt"
eq "stdout is PROCEED + prompt" "$expected" "$(out)"
eq "stderr is empty" "" "$(err)"
eq "pending written for finish" "deadbeef
cafef00d" "$(cat "$STATE/pending-7" 2>/dev/null)"
eq "log went to the file instead" "1" \
  "$(grep -c 'PR #7: first review' "$HOME/.claude/pr-review/review-acme-widgets.log")"
cleanup

echo "== a closed PR is a bare SKIP =="
new_sandbox
PR_STATE=CLOSED preflight 7 review_requested
eq "stdout is SKIP" "SKIP" "$(out)"
eq "stderr is empty" "" "$(err)"
cleanup

echo "== an unfetchable PR is a bare SKIP =="
new_sandbox
PR_STATE=none preflight 7 review_requested
eq "stdout is SKIP" "SKIP" "$(out)"
eq "stderr is empty" "" "$(err)"
cleanup

echo "== an unresolvable head is a bare SKIP, with nothing pending =="
new_sandbox
STATE="$HOME/.claude/pr-review/state/acme-widgets"
HEAD_FAIL=1 preflight 7 review_requested
eq "stdout is SKIP" "SKIP" "$(out)"
eq "stderr is empty" "" "$(err)"
eq "no pending file" "absent" "$([ -e "$STATE/pending-7" ] && echo present || echo absent)"
cleanup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
