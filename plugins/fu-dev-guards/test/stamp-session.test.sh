#!/usr/bin/env bash
# Tests for the SessionStart session-id stamper.
# No framework — run: bash plugins/fu-dev-guards/test/stamp-session.test.sh
#
# Hermetic: the hook's only input is the JSON on stdin, so there is nothing to
# stub. The one case that needs a filesystem (the jq-missing probe) gets a
# throwaway mktemp dir — no fixed path is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../src/hooks/stamp-session-sessionstart.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# run <json-on-stdin> -> sets RC, OUT, ERR
# Stderr is captured, never discarded: "silent" has to mean silent on BOTH
# streams, or a hook that prints a jq parse error at every SessionStart passes.
run() {
  ERR=$(bash "$HOOK" <<<"$1" 2>"$TMP/err" >"$TMP/out"; echo $? >"$TMP/rc"; cat "$TMP/err")
  RC=$(cat "$TMP/rc"); OUT=$(cat "$TMP/out")
}

SID=9a10211d-a53b-4515-991c-ccddd70b9933
OTHER=011eb776-4a5a-48b3-89fb-537698f73e9c

echo "== emits a well-formed SessionStart payload =="

run "{\"session_id\":\"$SID\"}"
[ "$RC" -eq 0 ] && ok || bad "exit status should be 0 (got $RC)"
[ -z "$ERR" ] && ok || bad "happy path should write nothing to stderr (got <$ERR>)"

jq -e . <<<"$OUT" >/dev/null 2>&1 && ok || bad "output should be parseable JSON: <$OUT>"

# One object, not a stream — a second object would be silently dropped or worse.
[ "$(jq -s 'length' <<<"$OUT" 2>/dev/null)" = 1 ] && ok || bad "output should be exactly one JSON object"

[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$OUT" 2>/dev/null)" = "SessionStart" ] &&
  ok || bad "hookEventName should be SessionStart"

ctx=$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$OUT" 2>/dev/null)
[ -n "$ctx" ] && ok || bad "additionalContext should be non-empty"

echo "== the context carries the marker, built from the input id =="

# The exact string a PR body has to end up containing. If this assertion is
# edited, every PR stamped by an older session stops matching the new grep —
# so treat the marker text as a wire format, not a wording choice.
grep -qF -- "<!-- claude-session: $SID -->" <<<"$ctx" &&
  ok || bad "context should contain the verbatim marker for the input id"

# The marker must survive as ONE line: split across two, no grep finds it again.
[ "$(grep -cF -- "<!-- claude-session: $SID -->" <<<"$ctx")" = 1 ] &&
  ok || bad "marker should appear exactly once, on a single line"

# The id must come from stdin, never a constant: two runs, two ids.
run "{\"session_id\":\"$OTHER\"}"
ctx2=$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$OUT" 2>/dev/null)
grep -qF -- "<!-- claude-session: $OTHER -->" <<<"$ctx2" &&
  ok || bad "marker should use the id from stdin, not a hardcoded one"
grep -qF -- "$SID" <<<"$ctx2" &&
  bad "context leaked the previous run's id" || ok

echo "== the instruction says the things it has to say =="

run "{\"session_id\":\"$SID\"}"
ctx=$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$OUT" 2>/dev/null)

# Placement: the bottom of the body. The wording must NOT claim the last line —
# the harness separately requires PR bodies to end with the Generated-with
# footer, and two rules both claiming last place get resolved at random.
grep -qi 'very bottom' <<<"$ctx" && ok || bad "instruction should place the marker at the bottom"
grep -qi 'last line'   <<<"$ctx" && bad "instruction must not claim the LAST line (collides with the footer)" || ok
grep -qF 'Generated with Claude Code' <<<"$ctx" &&
  ok || bad "instruction should state its order relative to the Generated-with footer"

# Without a PreToolUse backstop this sentence is the only thing keeping the
# marker alive across a body rewrite.
grep -qF 'gh pr edit' <<<"$ctx" && ok || bad "instruction should cover gh pr edit --body"

echo "== stays silent when there is no id to stamp =="
# Silence on both streams, not a broken payload: a hook that emits half a
# message every session is worse than one that says nothing.

for bad_input in \
  '{"session_id":""}' \
  '{"session_id":null}' \
  '{"cwd":"/tmp"}' \
  '{' \
  'not json at all' \
  ''; do
  run "$bad_input"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then ok
  else bad "should be silent on both streams + rc 0 for <$bad_input> (rc=$RC out=$OUT err=$ERR)"; fi
done

echo "== an id that would break the wire format is refused, not emitted =="
# The marker is a single-line HTML comment. An id carrying a newline splits it in
# half; one carrying `>` can close the comment early. Emptiness alone is not a
# sufficient check, and these are the input classes that actually corrupt the
# format — unlike a `$(...)` payload, which bash never re-evaluates out of an
# expanded variable and so cannot execute no matter how the payload is built.

# shellcheck disable=SC2016
for hostile in \
  'aa
bb' \
  'a--> <!-- b' \
  'a b' \
  'a"b' \
  '$(touch pwned)' \
  '`id`'; do
  run "$(jq -nc --arg s "$hostile" '{session_id: $s}')"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok
  else bad "wire-format-breaking id should be refused: <$hostile> (out=$OUT)"; fi
done

# A non-string id must not be pretty-printed into the marker across three lines.
run '{"session_id":{"x":1}}'
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "object id should be refused (out=$OUT)"

# The whole valid charset must still pass — the guard above must not be so tight
# that a legitimate id is rejected.
run '{"session_id":"Aa0._-9"}'
grep -qF -- '<!-- claude-session: Aa0._-9 -->' \
  <<<"$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$OUT" 2>/dev/null)" &&
  ok || bad "a legitimate id using the full charset should still be stamped"

echo "== a missing jq is reported, not silently swallowed =="
# jq absent is an install fault the user can fix; silence would be
# indistinguishable from "no session id" and stamping would never happen again.
ERR2=$(PATH="$TMP/empty-path" /bin/bash "$HOOK" <<<"{\"session_id\":\"$SID\"}" 2>&1 >/dev/null); RC2=$?
[ "$RC2" -eq 0 ] && ok || bad "missing jq should not fail the session (rc=$RC2)"
grep -qi 'jq not found' <<<"$ERR2" && ok || bad "missing jq should say so on stderr (got <$ERR2>)"

echo
printf 'PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
