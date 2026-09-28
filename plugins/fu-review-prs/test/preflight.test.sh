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
  #   HEAD_TREE  — the head's tree SHA (default cafef00d)
  #   PR_FILES   — the PR's files, one per line; the stub serves them as TWO
  #                pages and returns only the first page without --paginate
  #   FILES_FAIL — non-empty makes the PR file-list fetch fail
  #   COMPARE_FILES / COMPARE_FAIL — the compare's files, or make it fail;
  #                the compare's range is recorded in $GH_COMPARE
  export GH_COMPARE="$SANDBOX/gh-compare.txt"
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
if [ "$1" = "api" ] && [[ "$2" == *"/commits/"* ]]; then echo "${HEAD_TREE:-cafef00d}"; exit 0; fi
if [ "$1" = "api" ] && [[ "$2" == *"/pulls/"*"/files" ]]; then
  [ -n "${FILES_FAIL:-}" ] && exit 1
  files=${PR_FILES-$'src/a.cs\nsrc/b.cs'}
  if [[ "$*" == *"--paginate"* ]]; then printf '%s\n' "$files"
  else printf '%s\n' "$files" | head -1; fi
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" == *"/compare/"* ]]; then
  echo "${2##*/compare/}" > "$GH_COMPARE"
  [ -n "${COMPARE_FAIL:-}" ] && exit 1
  printf '%s\n' "${COMPARE_FILES-}"
  exit 0
fi
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
  unset PR_STATE HEAD_FAIL HEAD_TREE PR_FILES FILES_FAIL COMPARE_FILES COMPARE_FAIL \
        CLAUDE_PLUGIN_ROOT REVIEW_TASK_FILE
  STATE="$HOME/.claude/pr-review/state/acme-widgets"
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
scope() { cat "$STATE/scope-7.txt" 2>/dev/null; }
# A prior review of PR 7 at commit 0ldc0mm1t / tree <tree>. reviewed <tree>
reviewed() { mkdir -p "$STATE"; printf '0ldc0mm1t\n%s\n' "$1" > "$STATE/last-reviewed-7"; }
# scope_file <mode> <delta_base> <files...>
scope_file() {
  local mode=$1 base=$2; shift 2
  printf 'REPO=acme/widgets\nHEAD=deadbeef\nMODE=%s\nDELTA_BASE=%s\n\n' "$mode" "$base"
  printf '%s\n' "$@"
}

echo "== PROCEED is followed by the ready Task prompt =="
new_sandbox
preflight 7 review_requested
expected="PROCEED
Read $ROOT/review-task.md and follow it exactly. Review PR #7.
Use these absolute paths verbatim — do not construct your own:
  SCOPE_FILE = $STATE/scope-7.txt
  PRIOR_FILE = $STATE/prior-7.txt
  BODY_FILE = $STATE/review-body-7.md
  DECISION_FILE = $STATE/decision-7.txt"
eq "stdout is PROCEED + prompt" "$expected" "$(out)"
eq "stderr is empty" "" "$(err)"
eq "pending written for finish" "commit=deadbeef
tree=cafef00d" "$(cat "$STATE/pending-7" 2>/dev/null)"
eq "log went to the file instead" "1" \
  "$(grep -c 'PR #7: FULL review (first review), 2 file(s)' "$HOME/.claude/pr-review/review-acme-widgets.log")"
eq "first review: FULL scope, every PR file" "$(scope_file FULL '' src/a.cs src/b.cs)" "$(scope)"
cleanup

echo "== the PR file list is paginated =="
new_sandbox
PR_FILES=$'src/a.cs\nsrc/b.cs\nsrc/c.cs' preflight 7 review_requested
eq "all pages read" "$(scope_file FULL '' src/a.cs src/b.cs src/c.cs)" "$(scope)"
cleanup

echo "== tree unchanged (a re-request): FULL, no compare =="
new_sandbox
reviewed cafef00d
preflight 7 review_re_requested
eq "stdout starts PROCEED" "PROCEED" "$(out | head -1)"
eq "FULL scope" "$(scope_file FULL '' src/a.cs src/b.cs)" "$(scope)"
eq "compare never called" "absent" "$([ -e "$GH_COMPARE" ] && echo present || echo absent)"
cleanup

echo "== tree changed: DELTA over PR files ∩ changed files =="
new_sandbox
reviewed 01dtree
COMPARE_FILES=$'src/b.cs\nlib/from-main.cs' preflight 7 review_re_requested
eq "DELTA scope, rebased-in file excluded" "$(scope_file DELTA 0ldc0mm1t src/b.cs)" "$(scope)"
eq "compare from last reviewed commit to head" "0ldc0mm1t...deadbeef" "$(cat "$GH_COMPARE")"
cleanup

echo "== tree changed but no PR file did: FULL =="
new_sandbox
reviewed 01dtree
COMPARE_FILES='lib/from-main.cs' preflight 7 review_re_requested
eq "falls back to FULL" "$(scope_file FULL '' src/a.cs src/b.cs)" "$(scope)"
cleanup

echo "== compare fails: FULL =="
new_sandbox
reviewed 01dtree
COMPARE_FAIL=1 preflight 7 review_re_requested
eq "stdout starts PROCEED" "PROCEED" "$(out | head -1)"
eq "falls back to FULL" "$(scope_file FULL '' src/a.cs src/b.cs)" "$(scope)"
cleanup

echo "== compare at its 300-file cap: FULL =="
new_sandbox
reviewed 01dtree
COMPARE_FILES=$(printf 'src/a.cs\n'; seq -f 'gen/f%g.cs' 299) preflight 7 review_re_requested
eq "falls back to FULL" "$(scope_file FULL '' src/a.cs src/b.cs)" "$(scope)"
cleanup

echo "== the PR file list can't be fetched: SKIP, nothing pending =="
new_sandbox
FILES_FAIL=1 preflight 7 review_requested
eq "stdout is SKIP" "SKIP" "$(out)"
eq "stderr is empty" "" "$(err)"
eq "no pending file" "absent" "$([ -e "$STATE/pending-7" ] && echo present || echo absent)"
eq "no scope file" "" "$(scope)"
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

echo "== a pending record that can't be written is a SKIP, not a PROCEED =="
new_sandbox
mkdir -p "$STATE/pending-7"   # a directory where the record goes: the write fails
preflight 7 review_requested
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
