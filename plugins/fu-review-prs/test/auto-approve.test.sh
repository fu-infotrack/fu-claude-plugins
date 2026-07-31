#!/usr/bin/env bash
# Tests for the posting-policy gate in scripts/lib.sh — COMMENT is the default and
# APPROVE requires an explicit opt-in. No framework — run:
#   bash plugins/fu-review-prs/test/auto-approve.test.sh
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
has()    { if grep -qF -- "$2" <<<"$3"; then ok; else bad "$1 (missing <$2>)"; fi; }
has_no() { if grep -qF -- "$2" <<<"$3"; then bad "$1 (unexpected <$2>)"; else ok; fi; }

SANDBOX=""
new_sandbox() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$SANDBOX/bin"
  export GH_POST="$SANDBOX/gh-post.txt"
  # gh stub: answers the repo lookup and records a posted review's flags.
  cat >"$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/widgets"; exit 0 ;;
  "api user")  echo "bot"; exit 0 ;;
  "pr list")   echo "7"; exit 0 ;;   # both the open-PR and review-requested queries
esac
if [ "$1" = "api" ] && [[ "$2" == *"/reviews" ]]; then
  # A POST is a review being submitted; a GET is the prior-review lookup (none).
  [[ "$*" == *"--method POST"* ]] && printf '%s\n' "$@" > "$GH_POST"
  exit 0
fi
exit 0
STUB
  # git stub: lib.sh asks for the toplevel at source time, then whether the review
  # clone is a work tree — answering "no" makes pr_review_reset_tree a no-op.
  cat >"$SANDBOX/bin/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "--is-inside-work-tree" ] && exit 1
done
for a in "$@"; do
  [ "$a" = "rev-parse" ] && { echo "/nonexistent/review-clone"; exit 0; }
done
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/git"
  export PATH="$SANDBOX/bin:$PATH"
  unset PR_REVIEW_AUTO_APPROVE
}
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Source lib.sh in a fresh shell per case (it computes its paths at source time),
# seed one PR's sub-agent output on disk, then run the requested commands.
# run <pr> <decision> <shell-snippet>
run() {
  local pr=$1 decision=$2 snippet=$3
  bash -c '
    set -uo pipefail
    source "$1"
    pr=$2; decision=$3
    printf "<!-- DECISION: %s -->\n### Code review — PR #%s\nFound 0 issues:\n" "$decision" "$pr" \
      > "$STATE_DIR/review-body-$pr.md"
    printf "%s\n" "$decision" > "$STATE_DIR/decision-$pr.txt"
    write_pending "$pr" deadbeef cafef00d
    eval "$4"
  ' _ "$LIB" "$pr" "$decision" "$snippet" 2>/dev/null
}

# Drive pr_review_init end-to-end (real flock holder, stubbed gh/git) and report
# both its queue output and whether it recorded the auto-approve mode.
# Its output goes to a FILE, never a command substitution: the background lock
# holder inherits stdout, so `$(pr_review_init)` would block until the holder's
# 7200s timeout. run_init <args...>
run_init() {
  local out="$SANDBOX/init.out"
  bash -c '
    set -uo pipefail
    source "$1"; out=$2; shift 2
    pr_review_init "$@" > "$out"
    auto_approve_enabled && mode=on || mode=off
    pr_review_release_lock
    printf "mode=%s\n" "$mode" >> "$out"
  ' _ "$LIB" "$out" "$@" 2>/dev/null
  cat "$out"
}

posted_event() { sed -n '/^event=/{s/^event=//p;}' "$GH_POST" 2>/dev/null; }
posted_body()  { cat "$GH_POST" 2>/dev/null; }

echo "== default (no flag): an APPROVE decision posts as COMMENT =="
new_sandbox
run 7 APPROVE 'pr_review_set_mode; pr_review_finish 7'
eq "posted event" "COMMENT" "$(posted_event)"
has "body explains the downgrade" "auto-approve is off" "$(posted_body)"
has "findings still posted" "Found 0 issues" "$(posted_body)"
cleanup

echo "== --auto-approve: an APPROVE decision posts as APPROVE =="
new_sandbox
run 7 APPROVE 'pr_review_set_mode --auto-approve; pr_review_finish 7'
eq "posted event" "APPROVE" "$(posted_event)"
has_no "no downgrade note" "auto-approve is off" "$(posted_body)"
cleanup

echo "== --approve is accepted as an alias =="
new_sandbox
run 7 APPROVE 'pr_review_set_mode --approve; pr_review_finish 7'
eq "posted event" "APPROVE" "$(posted_event)"
cleanup

echo "== PR_REVIEW_AUTO_APPROVE=1 enables it without a flag =="
new_sandbox
PR_REVIEW_AUTO_APPROVE=1 run 7 APPROVE 'pr_review_set_mode; pr_review_finish 7'
eq "posted event" "APPROVE" "$(posted_event)"
cleanup

echo "== a COMMENT decision is never upgraded, even with the flag =="
new_sandbox
run 7 COMMENT 'pr_review_set_mode --auto-approve; pr_review_finish 7'
eq "posted event" "COMMENT" "$(posted_event)"
has_no "no downgrade note (nothing was downgraded)" "auto-approve is off" "$(posted_body)"
cleanup

echo "== the flag does not leak: a later tick without it re-declares COMMENT =="
new_sandbox
run 7 APPROVE 'pr_review_set_mode --auto-approve; pr_review_set_mode; pr_review_finish 7'
eq "posted event" "COMMENT" "$(posted_event)"
cleanup

echo "== cleanup clears the flag =="
new_sandbox
out=$(run 7 APPROVE 'pr_review_set_mode --auto-approve
  auto_approve_enabled && echo BEFORE=on
  pr_review_cleanup >/dev/null
  auto_approve_enabled && echo AFTER=on || echo AFTER=off')
has "flag set before cleanup" "BEFORE=on" "$out"
has "flag cleared by cleanup" "AFTER=off" "$out"
cleanup

echo "== an unknown argument is ignored, not treated as opt-in =="
new_sandbox
run 7 APPROVE 'pr_review_set_mode --yolo; pr_review_finish 7'
eq "posted event" "COMMENT" "$(posted_event)"
cleanup

echo "== pr_review_init records the mode from its arguments =="
new_sandbox
out=$(run_init --auto-approve)
has "queue detected" "7 review_requested" "$out"
has "--auto-approve recorded" "mode=on" "$out"
cleanup

echo "== pr_review_init with no arguments records comment-only =="
new_sandbox
out=$(run_init)
has "queue detected" "7 review_requested" "$out"
has "no flag recorded" "mode=off" "$out"
cleanup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
