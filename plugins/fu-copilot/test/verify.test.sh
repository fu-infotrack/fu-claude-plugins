#!/usr/bin/env bash
# Hermetic tests for verify.sh, against throwaway git fixtures. No network, no
# real Copilot run; `wait` is exercised against ordinary background sleeps.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
VERIFY="$HERE/../scripts/verify.sh"
pass=0 fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "$2";; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "$2";; *) ok "$1";; esac; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
R="$SANDBOX/repo"
git init -q "$R"
gc() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }

echo "a" > "$R/a.txt"; gc add -A; gc commit -q -m "one"
PRE=$(git -C "$R" rev-parse HEAD)
echo "b" > "$R/b.txt"; gc add -A; gc commit -q -m "two"
gc commit -q --allow-empty -m "empty on purpose"
echo "c" > "$R/c.txt"; gc add -A; gc commit -q -m "three"
HEAD_NOW=$(git -C "$R" rev-parse HEAD)

echo "verify.sh wait"

out=$("$VERIFY" wait 2>&1); check "wait without pid exits 2" "$?" "2"
out=$("$VERIFY" wait notanumber 2>&1); check "wait with non-numeric pid exits 2" "$?" "2"
has "non-numeric pid is named" "$out" "must be numeric"

sleep 1 & p=$!
out=$("$VERIFY" wait "$p" --poll 1 2>&1); rc=$?
check "wait returns 0 once the process exits" "$rc" "0"
has "wait reports EXITED: yes" "$out" "EXITED: yes"
has "wait reports ELAPSED" "$out" "ELAPSED:"

sleep 30 & p=$!
out=$("$VERIFY" wait "$p" --poll 1 --timeout 2 2>&1); rc=$?
check "wait exits 1 on timeout" "$rc" "1"
has "timeout says still running" "$out" "still running"
kill "$p" 2>/dev/null

# An already-dead pid must return immediately rather than hang.
sleep 0.1 & p=$!; wait "$p" 2>/dev/null
out=$("$VERIFY" wait "$p" --poll 1 --timeout 5 2>&1); check "dead pid returns 0 at once" "$?" "0"

echo "verify.sh check"

out=$("$VERIFY" check 2>&1); check "check without --cwd exits 2" "$?" "2"
out=$("$VERIFY" check --cwd "$SANDBOX" 2>&1); check "check on a non-repo exits 2" "$?" "2"
out=$("$VERIFY" check --cwd "$R" --bogus x 2>&1); check "check with unknown flag exits 2" "$?" "2"
out=$("$VERIFY" nonsense 2>&1); check "unknown subcommand exits 2" "$?" "2"

# --- HEAD_MOVED: the headline check ----------------------------------------
out=$("$VERIFY" check --cwd "$R" --baseline "$PRE" 2>&1); rc=$?
check "moved HEAD passes" "$rc" "0"
has "HEAD_MOVED PASS" "$out" "HEAD_MOVED:      PASS"

out=$("$VERIFY" check --cwd "$R" --baseline "$HEAD_NOW" 2>&1); rc=$?
check "unmoved HEAD fails" "$rc" "1"
has "HEAD_MOVED FAIL" "$out" "HEAD_MOVED:      FAIL"
has "unmoved HEAD says it changed nothing" "$out" "changed nothing"

out=$("$VERIFY" check --cwd "$R" 2>&1)
has "no baseline is a SKIP not a pass" "$out" "HEAD_MOVED:      SKIP"

# --- EMPTY_COMMITS ---------------------------------------------------------
out=$("$VERIFY" check --cwd "$R" --range "${PRE}..HEAD" 2>&1); rc=$?
check "range containing an empty commit fails" "$rc" "1"
has "EMPTY_COMMITS FAIL" "$out" "EMPTY_COMMITS:   FAIL"
has "the empty commit's subject is named" "$out" "empty on purpose"

# HEAD~1 is the deliberately-empty commit, so HEAD~1..HEAD holds only "three".
CLEAN_FROM=$(git -C "$R" rev-parse HEAD~1)
out=$("$VERIFY" check --cwd "$R" --range "${CLEAN_FROM}..HEAD" 2>&1)
has "range with no empty commits passes" "$out" "EMPTY_COMMITS:   PASS"

# The reported count must match the number of commits actually listed.
out=$("$VERIFY" check --cwd "$R" --range "${PRE}..HEAD" 2>&1)
has "one empty commit is counted as 1, not 0" "$out" "1 empty in"

out=$("$VERIFY" check --cwd "$R" 2>&1)
has "no range is a SKIP" "$out" "EMPTY_COMMITS:   SKIP"

# --- LOSSLESS, including the vacuous case ----------------------------------
git -C "$R" branch -q side "$PRE"
S="$SANDBOX/side"; git clone -q "$R" "$S" 2>/dev/null
git -C "$S" -c advice.detachedHead=false checkout -q "$PRE"
out=$("$VERIFY" check --cwd "$S" --baseline "$PRE" --lossless-from "$PRE" 2>&1); rc=$?
check "lossless+unmoved HEAD fails" "$rc" "1"
has "vacuous lossless is called out" "$out" "vacuous"

out=$("$VERIFY" check --cwd "$R" --baseline "$PRE" --lossless-from "$PRE" 2>&1); rc=$?
check "genuine content change fails lossless" "$rc" "1"
has "LOSSLESS FAIL shows the shortstat" "$out" "LOSSLESS:        FAIL"

git -C "$R" tag -f lossless-base "$HEAD_NOW" >/dev/null 2>&1
out=$("$VERIFY" check --cwd "$R" --baseline "$PRE" --lossless-from lossless-base 2>&1)
has "identical tree passes lossless" "$out" "LOSSLESS:        PASS"

out=$("$VERIFY" check --cwd "$R" --lossless-from deadbeefdeadbeef 2>&1); rc=$?
check "unknown lossless commit fails" "$rc" "1"
has "unknown commit is named" "$out" "unknown commit"

# --- WORKTREE_CLEAN --------------------------------------------------------
out=$("$VERIFY" check --cwd "$R" 2>&1)
has "clean tree passes" "$out" "WORKTREE_CLEAN:  PASS"
echo "dirty" > "$R/dirty.txt"
out=$("$VERIFY" check --cwd "$R" 2>&1); rc=$?
check "dirty tree fails" "$rc" "1"
has "dirty tree counts paths" "$out" "uncommitted path(s)"
rm -f "$R/dirty.txt"

# --- LOG scanning ----------------------------------------------------------
GOOD="$SANDBOX/good.log"
printf 'did the work\nResume     copilot --resume=abc12345-1111-2222-3333-444455556666\n' > "$GOOD"
out=$("$VERIFY" check --cwd "$R" --log "$GOOD" 2>&1); rc=$?
check "clean log passes" "$rc" "0"
has "LOG_PERMISSION PASS" "$out" "LOG_PERMISSION:  PASS"
has "resume handle surfaced" "$out" "copilot --resume=abc12345"
has "log size reported" "$out" "bytes --"

# MEASURED against a real run: --no-color does NOT strip ANSI from the stats
# footer, so the resume handle arrives wrapped in escapes. Extraction must cope.
ANSI="$SANDBOX/ansi.log"
printf 'PONG\n\n\033[38;2;145;152;161mResume     \033[39mcopilot --resume=c5c958b5-9a7d-451c-9989-2c719f79382b\n' > "$ANSI"
out=$("$VERIFY" check --cwd "$R" --log "$ANSI" 2>&1)
has "resume handle survives ANSI escapes" "$out" "copilot --resume=c5c958b5-9a7d-451c-9989-2c719f79382b"

DENIED="$SANDBOX/denied.log"
printf 'reading brief\n  L Permission denied and could not request permission from user\n' > "$DENIED"
out=$("$VERIFY" check --cwd "$R" --log "$DENIED" 2>&1); rc=$?
check "permission-denied log fails" "$rc" "1"
has "denial is called BLOCKING" "$out" "BLOCKING"
has "denial warns it guessed" "$out" "guessed"

out=$("$VERIFY" check --cwd "$R" --log "$SANDBOX/absent.log" 2>&1); rc=$?
check "unreadable log fails" "$rc" "1"

out=$("$VERIFY" check --cwd "$R" 2>&1)
has "no log is a SKIP" "$out" "LOG_PERMISSION:  SKIP"

# --- usage reporting -------------------------------------------------------
# Reported, never graded: the AI-credit cap is a SOFT cap, so a capped run stops
# between model calls with its work half-done and every git check still passing.
# Whether that happened is for the caller to read, not for this script to decide.
U="$SANDBOX/run.usage.json"
printf '{"ai_credits_used": 100, "model": "gpt-5.6-luna"}\n' > "$U"
out=$("$VERIFY" check --cwd "$R" --baseline "$PRE" --usage "$U" 2>&1); rc=$?
check "usage file does not affect the verdict" "$rc" "0"
has "usage line printed" "$out" "USAGE:"
has "credits used surfaced" "$out" "ai_credits_used"

out=$("$VERIFY" check --cwd "$R" --baseline "$PRE" --usage "$SANDBOX/never-written.json" 2>&1); rc=$?
check "missing usage file does not fail the run" "$rc" "0"
has "missing usage file says so" "$out" "not written"

# Copilot may write something jq cannot parse; report it rather than swallow it.
printf 'not json at all\n' > "$SANDBOX/bad.json"
out=$("$VERIFY" check --cwd "$R" --baseline "$PRE" --usage "$SANDBOX/bad.json" 2>&1)
has "unparseable usage file still reported" "$out" "not json at all"

out=$("$VERIFY" check --cwd "$R" --baseline "$PRE" 2>&1)
hasnt "no --usage prints no usage line" "$out" "USAGE:"

# --- verdict wording -------------------------------------------------------
out=$("$VERIFY" check --cwd "$R" --baseline "$PRE" 2>&1)
has "passing verdict is plain" "$out" "VERDICT: all applicable checks passed"
out=$("$VERIFY" check --cwd "$R" --baseline "$HEAD_NOW" 2>&1)
has "failing verdict distrusts summaries" "$out" "before believing any summary"

# A run where every check is skipped must not read as success.
out=$("$VERIFY" check --cwd "$R" 2>&1)
hasnt "all-skipped run does not claim checks passed" "$out" "HEAD_MOVED:      PASS"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
