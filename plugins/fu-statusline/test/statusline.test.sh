#!/usr/bin/env bash
# Tests for the statusline renderer. No framework — run:
#   bash plugins/fu-statusline/test/statusline.test.sh
#
# The golden expectations are derived by hand from docs/ccstatusline-spec.md,
# not captured from this implementation, so a formatting regression fails here
# rather than silently redefining the format.
#
# The clock is pinned with CC_SL_NOW and the cache is redirected with
# XDG_CACHE_HOME, so no case touches real state or the wall clock. The two git
# cache cases are the exception and say why.
#
# Not covered: the `head -c` bound on the incremental read. It only matters when
# the transcript grows *between* the stat and the read, which a shell test
# cannot stage deterministically. Removing that bound still passes this suite.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SL="$ROOT/statusline.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

eq() { # eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else
    bad "$1
    expected: $(printf '%s' "$2" | cat -v)
    actual:   $(printf '%s' "$3" | cat -v)"
  fi
}

ESC=$'\033'
NB=$' '
NOW=1785000000

# 256-colour widget, matching `w($text; $c)` in the renderer.
c() { printf '%s[38;5;%sm%s%s[39m' "$ESC" "$1" "$2" "$ESC"; }
# One assembled line: ESC[0m prefix, then every space becomes a non-breaking
# space (ccstatusline applies that substitution to the whole line).
ln_() { local s="$*"; printf '%s[0m%s' "$ESC" "${s// /$NB}"; }

SANDBOX=""
new_sandbox() {
  SANDBOX=$(mktemp -d)
  export XDG_CACHE_HOME="$SANDBOX/cache"
  mkdir -p "$SANDBOX/nogit"
}
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

render() { CC_SL_NOW=$NOW bash "$SL"; }

# A payload with every field the five lines read.
payload() { # payload <session_id> <transcript_path> <cwd>
  jq -nc \
    --arg sid "$1" --arg tp "$2" --arg cwd "$3" --argjson now "$NOW" '{
      session_id: $sid,
      transcript_path: $tp,
      cwd: $cwd,
      effort: { level: "xhigh" },
      model: { id: "claude-opus-5", display_name: "Opus 5 (1M context)" },
      version: "2.1.220",
      cost: { total_cost_usd: 80.09 },
      context_window: {
        total_input_tokens: 147000,
        context_window_size: 1000000,
        used_percentage: 15
      },
      rate_limits: {
        five_hour:  { used_percentage: 33,                  resets_at: ($now + 2160) },
        seven_day:  { used_percentage: 28.000000000000004,  resets_at: ($now + 232560) }
      }
    }'
}

# Transcript entries, in file order.
#  1. counted           cached 1500, in 10, out 100
#  2. stop_reason null mid-file — a partial from a streamed reply, NOT counted
#  3. the /rename title the session-name widget shows
#  4. counted           cached 2000, in  5, out  50
#  5. stop_reason null and last — counted provisionally
#     => cached 3800, in 16, out 157, total 3973
transcript() {
  cat <<'JSONL'
{"type":"assistant","message":{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":100,"cache_creation_input_tokens":500,"cache_read_input_tokens":1000}}}
{"type":"assistant","message":{"stop_reason":null,"usage":{"input_tokens":999,"output_tokens":999,"cache_creation_input_tokens":9999,"cache_read_input_tokens":9999}}}
{"type":"custom-title","customTitle":"log-sweep"}
{"type":"assistant","message":{"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":2000}}}
{"type":"assistant","message":{"stop_reason":null,"usage":{"input_tokens":1,"output_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":300}}}
JSONL
}

# The five expected lines for the fixture above, worked out from the spec:
#   model      "Opus 5 (1M context)" -> parenthetical stripped
#   context    147000/1000000 = 14.7% -> round(1.47) = 1 filled cell of 10,
#              but the printed percentage is the payload's already-rounded 15
#   tokens     3800 -> "3.8k"; 3973 -> fix1(3.973) = "4.0k"
#   five_hour  2160s   -> "36m"
#   seven_day  232560s -> 64h36m -> "2d 16hr 36m"
expected_golden() { # expected_golden <cwd>
  ln_ "$(c 30 'Opus 5') $(c 96 xhigh) $(c 26 '▓░░░░░░░░░ 147k/1.0M (15%)') $(c 30 log-sweep)"
  printf '\n'
  ln_ "$(c 96 '⎇ no git') $(c 178 '(no git)')"
  printf '\n'
  ln_ "$(c 26 "$1")"
  printf '\n'
  ln_ "$(c 70 '$80.09') $(c 30 3.8k) $(c 26 16) $(c 188 157) $(c 30 4.0k)"
  printf '\n'
  ln_ "$(c 111 33.0%) $(c 111 36m) $(c 111 28.0%) $(c 111 '2d 16hr 36m')"
}

echo "== golden: five lines, exact bytes =="
new_sandbox
transcript >"$SANDBOX/t.jsonl"
out=$(payload s1 "$SANDBOX/t.jsonl" "$SANDBOX/nogit" | render); rc=$?
eq "exit 0" "0" "$rc"
eq "rendered output" "$(expected_golden "$SANDBOX/nogit")" "$out"
eq "line count" "5" "$(printf '%s\n' "$out" | wc -l)"
cleanup

echo "== incremental reads match a cold full scan =="
new_sandbox
full="$SANDBOX/full.jsonl"
grow="$SANDBOX/grow.jsonl"
transcript >"$full"
: >"$grow"
# Feed the same content in three growing chunks, rendering after each.
head -n 2 "$full" >"$grow"
payload sA "$grow" "$SANDBOX/nogit" | render >/dev/null
head -n 4 "$full" >"$grow"
payload sA "$grow" "$SANDBOX/nogit" | render >/dev/null
cp "$full" "$grow"
incremental=$(payload sA "$grow" "$SANDBOX/nogit" | render)
# A different session id starts from an empty cache: one cold full scan.
cold=$(payload sB "$full" "$SANDBOX/nogit" | render)
eq "incremental == cold" "$cold" "$incremental"
eq "cold == golden" "$(expected_golden "$SANDBOX/nogit")" "$cold"
cleanup

echo "== a half-written trailing line is skipped, then picked up =="
new_sandbox
t="$SANDBOX/t.jsonl"
transcript >"$t"
before=$(payload s1 "$t" "$SANDBOX/nogit" | render)
# Append a line with no terminating newline — a write caught mid-flight.
printf '%s' '{"type":"assistant","message":{"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >>"$t"
torn=$(payload s1 "$t" "$SANDBOX/nogit" | render)
eq "torn tick reuses the cached totals" "$before" "$torn"
printf '\n' >>"$t"
after=$(payload s1 "$t" "$SANDBOX/nogit" | render)
# Entry 5 was only counted because it was last, and the new entry demotes it —
# so its 300/1/7 drops back out while the new 0/100/200 comes in:
# stable 3500/15/150 + 0/100/200 => cached 3500, in 115, out 350, total 3965.
expected_after=$(
  ln_ "$(c 30 'Opus 5') $(c 96 xhigh) $(c 26 '▓░░░░░░░░░ 147k/1.0M (15%)') $(c 30 log-sweep)"
  printf '\n'
  ln_ "$(c 96 '⎇ no git') $(c 178 '(no git)')"
  printf '\n'
  ln_ "$(c 26 "$SANDBOX/nogit")"
  printf '\n'
  ln_ "$(c 70 '$80.09') $(c 30 3.5k) $(c 26 115) $(c 188 350) $(c 30 4.0k)"
  printf '\n'
  ln_ "$(c 111 33.0%) $(c 111 36m) $(c 111 28.0%) $(c 111 '2d 16hr 36m')"
)
eq "completed line is counted, provisional one demoted" "$expected_after" "$after"
cleanup

echo "== git widgets: branch plus staged and unstaged changes =="
new_sandbox
repo="$SANDBOX/repo"
mkdir -p "$repo"
git init -q "$repo" >/dev/null 2>&1
# Name the branch without relying on init.defaultBranch, which predates git 2.28.
git -C "$repo" symbolic-ref HEAD refs/heads/testbr >/dev/null 2>&1
printf '1\n' >"$repo/a.txt"
git -C "$repo" add a.txt >/dev/null 2>&1
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
printf '2\n' >"$repo/a.txt"      # staged:   +1 -1
git -C "$repo" add a.txt >/dev/null 2>&1
printf '3\n' >"$repo/a.txt"      # unstaged: +1 -1
transcript >"$SANDBOX/t.jsonl"
out=$(payload s1 "$SANDBOX/t.jsonl" "$repo" | render)
eq "branch and summed diffstat" \
  "$(ln_ "$(c 96 testbr) $(c 178 '(+2,-2)')")" \
  "$(printf '%s\n' "$out" | sed -n 2p)"
cleanup

echo "== git cache: per-directory key, and a live TTL =="
# These two cases must run on the real clock. CC_SL_NOW pinned to the past makes
# every cache entry look stale (now - mtime is negative), which would disable
# the very caching under test.
new_sandbox
repo="$SANDBOX/repo"
mkdir -p "$repo"
git init -q "$repo" >/dev/null 2>&1
# Name the branch without relying on init.defaultBranch, which predates git 2.28.
git -C "$repo" symbolic-ref HEAD refs/heads/testbr >/dev/null 2>&1
printf '1\n' >"$repo/a.txt"
git -C "$repo" add a.txt >/dev/null 2>&1
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
transcript >"$SANDBOX/t.jsonl"

# Render for a non-repo directory first, then the repo. One shared cache key
# would carry "no git" straight over — that was a real bug.
payload s1 "$SANDBOX/t.jsonl" "$SANDBOX/nogit" | bash "$SL" >/dev/null
out=$(payload s1 "$SANDBOX/t.jsonl" "$repo" | bash "$SL")
eq "repo not poisoned by the non-repo render" \
  "$(ln_ "$(c 96 testbr) $(c 178 '(+0,-0)')")" \
  "$(printf '%s\n' "$out" | sed -n 2p)"

# Within the TTL a second render must not re-shell out to git, so a change made
# in between is invisible until the entry expires.
printf '2\n' >"$repo/a.txt"
out=$(payload s1 "$SANDBOX/t.jsonl" "$repo" | bash "$SL")
eq "cached entry served inside the TTL" \
  "$(ln_ "$(c 96 testbr) $(c 178 '(+0,-0)')")" \
  "$(printf '%s\n' "$out" | sed -n 2p)"
cleanup

echo "== a transcript with no stop_reason field at all counts every entry =="
new_sandbox
t="$SANDBOX/t.jsonl"
cat >"$t" <<'JSONL'
{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":100,"cache_creation_input_tokens":500,"cache_read_input_tokens":1000}}}
{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":2000}}}
JSONL
out=$(payload s1 "$t" "$SANDBOX/nogit" | render | sed -n 4p)
# cached 3500, in 15, out 150, total 3665 -> fix1(3.665) = "3.7k"
eq "legacy totals" \
  "$(ln_ "$(c 70 '$80.09') $(c 30 3.5k) $(c 26 15) $(c 188 150) $(c 30 3.7k)")" \
  "$out"
cleanup

echo "== a malformed transcript line is skipped, not fatal =="
new_sandbox
t="$SANDBOX/t.jsonl"
{
  printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":100,"cache_creation_input_tokens":500,"cache_read_input_tokens":1000}}}'
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":'   # truncated, still matches the "usage" prefilter
  printf '%s\n' '{"type":"assistant","message":{"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":2000}}}'
} >"$t"
out=$(payload s1 "$t" "$SANDBOX/nogit" | render); rc=$?
eq "exit 0" "0" "$rc"
eq "totals ignore the bad line" \
  "$(ln_ "$(c 70 '$80.09') $(c 30 3.5k) $(c 26 15) $(c 188 150) $(c 30 3.7k)")" \
  "$(printf '%s\n' "$out" | sed -n 4p)"
cleanup

echo "== a fresh session with a sparse payload still renders =="
new_sandbox
sparse=$(jq -nc '{ session_id: "s9", transcript_path: "", cwd: "",
                   context_window: { current_usage: null } }')
out=$(printf '%s' "$sparse" | render); rc=$?
eq "exit 0" "0" "$rc"
# Every widget on lines 1 and 3 is empty except the context bar, and a line
# whose widgets are all empty is dropped entirely — so the cwd line disappears.
eq "line count" "4" "$(printf '%s\n' "$out" | wc -l)"
eq "context bar at zero" \
  "$(ln_ "$(c 26 '░░░░░░░░░░ 0/0 (0%)')")" \
  "$(printf '%s\n' "$out" | sed -n 1p)"
eq "zeroed cost and tokens" \
  "$(ln_ "$(c 70 '$0.00') $(c 30 0) $(c 26 0) $(c 188 0) $(c 30 0)")" \
  "$(printf '%s\n' "$out" | sed -n 3p)"
eq "zeroed usage and timers" \
  "$(ln_ "$(c 111 0.0%) $(c 111 0m) $(c 111 0.0%) $(c 111 0m)")" \
  "$(printf '%s\n' "$out" | sed -n 4p)"
cleanup

echo "== empty stdin exits quietly =="
new_sandbox
out=$(printf '' | render); rc=$?
eq "exit 0" "0" "$rc"
eq "no output" "" "$out"
cleanup

echo "== a shrinking transcript resets the cache instead of going negative =="
new_sandbox
t="$SANDBOX/t.jsonl"
transcript >"$t"
payload s1 "$t" "$SANDBOX/nogit" | render >/dev/null
# A compaction rewrites the transcript shorter than the recorded offset.
head -n 1 "$t" >"$t.small" && mv "$t.small" "$t"
out=$(payload s1 "$t" "$SANDBOX/nogit" | render | sed -n 4p)
# Only entry 1 remains: cached 1500, in 10, out 100, total 1610 -> "1.6k"
eq "totals recomputed from scratch" \
  "$(ln_ "$(c 70 '$80.09') $(c 30 1.5k) $(c 26 10) $(c 188 100) $(c 30 1.6k)")" \
  "$out"
cleanup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
