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

# Scheme A. Three tiers of grey for structure; hue only for state.
C_PRIMARY=253   # the two numbers worth reading
C_BODY=248      # identity fields
C_DETAIL=245    # detail, and anything at rest
C_OK=108        # under 60%
C_WARN=179      # 60-85%, and a dirty worktree
C_CRIT=174      # over 85%
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
  ln_ "$(c $C_PRIMARY 'Opus 5') $(c $C_DETAIL xhigh) $(c $C_OK '▓░░░░░░░░░ 147k/1.0M (15%)') $(c $C_BODY log-sweep)"
  printf '\n'
  ln_ "$(c $C_BODY '⎇ no git') $(c $C_DETAIL '(no git)')"
  printf '\n'
  ln_ "$(c $C_BODY "$1")"
  printf '\n'
  ln_ "$(c $C_BODY '$80.09') $(c $C_DETAIL 3.8k) $(c $C_DETAIL 16) $(c $C_DETAIL 157) $(c $C_PRIMARY 4.0k)"
  printf '\n'
  ln_ "$(c $C_OK 33.0%) $(c $C_DETAIL 36m) $(c $C_OK 28.0%) $(c $C_DETAIL '2d 16hr 36m')"
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
  ln_ "$(c $C_PRIMARY 'Opus 5') $(c $C_DETAIL xhigh) $(c $C_OK '▓░░░░░░░░░ 147k/1.0M (15%)') $(c $C_BODY log-sweep)"
  printf '\n'
  ln_ "$(c $C_BODY '⎇ no git') $(c $C_DETAIL '(no git)')"
  printf '\n'
  ln_ "$(c $C_BODY "$SANDBOX/nogit")"
  printf '\n'
  ln_ "$(c $C_BODY '$80.09') $(c $C_DETAIL 3.5k) $(c $C_DETAIL 115) $(c $C_DETAIL 350) $(c $C_PRIMARY 4.0k)"
  printf '\n'
  ln_ "$(c $C_OK 33.0%) $(c $C_DETAIL 36m) $(c $C_OK 28.0%) $(c $C_DETAIL '2d 16hr 36m')"
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
  "$(ln_ "$(c $C_BODY testbr) $(c $C_WARN '(+2,-2)')")" \
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
  "$(ln_ "$(c $C_BODY testbr) $(c $C_DETAIL '(+0,-0)')")" \
  "$(printf '%s\n' "$out" | sed -n 2p)"

# Within the TTL a second render must not re-shell out to git, so a change made
# in between is invisible until the entry expires.
printf '2\n' >"$repo/a.txt"
out=$(payload s1 "$SANDBOX/t.jsonl" "$repo" | bash "$SL")
eq "cached entry served inside the TTL" \
  "$(ln_ "$(c $C_BODY testbr) $(c $C_DETAIL '(+0,-0)')")" \
  "$(printf '%s\n' "$out" | sed -n 2p)"
cleanup

echo "== an empty field does not shift the fields after it =="
# Both cases below are the same defect: a tab is IFS *whitespace*, so bash
# collapses runs of it and an empty field silently shifts every later field
# left. Records are US-separated for exactly this reason.
new_sandbox
repo="$SANDBOX/repo"
mkdir -p "$repo"
git init -q "$repo" >/dev/null 2>&1
git -C "$repo" symbolic-ref HEAD refs/heads/testbr >/dev/null 2>&1
printf '1\n' >"$repo/a.txt"
git -C "$repo" add a.txt >/dev/null 2>&1
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1

# An absent transcript_path sits between session_id and cwd: collapsing it made
# cwd land in the transcript variable, and the git widgets read "no git".
no_tp=$(jq -nc --arg cwd "$repo" --argjson now "$NOW" '{
  session_id: "s1", transcript_path: "", cwd: $cwd,
  context_window: { total_input_tokens: 0, context_window_size: 0, used_percentage: 0 } }')
out=$(printf '%s' "$no_tp" | render)
eq "cwd survives an empty transcript_path" \
  "$(ln_ "$(c $C_BODY testbr) $(c $C_DETAIL '(+0,-0)')")" \
  "$(printf '%s\n' "$out" | sed -n 2p)"

# A detached HEAD has no branch name, and that empty field sits in the middle of
# the git cache record. Reading it back used to yield branch="0".
git -C "$repo" checkout -q --detach HEAD >/dev/null 2>&1
transcript >"$SANDBOX/t.jsonl"
# The render above cached this directory seconds ago and the TTL has not
# expired, so drop the cache rather than measuring the stale entry.
rm -rf "$XDG_CACHE_HOME/cc-statusline"
cold=$(payload s2 "$SANDBOX/t.jsonl" "$repo" | bash "$SL" | sed -n 2p)
warm=$(payload s2 "$SANDBOX/t.jsonl" "$repo" | bash "$SL" | sed -n 2p)
eq "detached HEAD drops the branch widget" "$(ln_ "$(c $C_DETAIL '(+0,-0)')")" "$cold"
eq "and the cached read agrees with the cold one" "$cold" "$warm"
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
  "$(ln_ "$(c $C_BODY '$80.09') $(c $C_DETAIL 3.5k) $(c $C_DETAIL 15) $(c $C_DETAIL 150) $(c $C_PRIMARY 3.7k)")" \
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
  "$(ln_ "$(c $C_BODY '$80.09') $(c $C_DETAIL 3.5k) $(c $C_DETAIL 15) $(c $C_DETAIL 150) $(c $C_PRIMARY 3.7k)")" \
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
  "$(ln_ "$(c $C_OK '░░░░░░░░░░ 0/0 (0%)')")" \
  "$(printf '%s\n' "$out" | sed -n 1p)"
eq "zeroed cost and tokens" \
  "$(ln_ "$(c $C_BODY '$0.00') $(c $C_DETAIL 0) $(c $C_DETAIL 0) $(c $C_DETAIL 0) $(c $C_PRIMARY 0)")" \
  "$(printf '%s\n' "$out" | sed -n 3p)"
eq "zeroed usage and timers" \
  "$(ln_ "$(c $C_OK 0.0%) $(c $C_DETAIL 0m) $(c $C_OK 0.0%) $(c $C_DETAIL 0m)")" \
  "$(printf '%s\n' "$out" | sed -n 4p)"
cleanup

echo "== severity: colour tracks the value, at the boundaries =="
# The whole point of Scheme A is that hue means "this crossed a threshold".
# Percent boundaries are: under 60 quiet, 60 through 85 amber, above 85 rose.
# The context bar grades absolute tokens on the same three tiers as well, and
# shows whichever of the two readings is worse.
new_sandbox
sev_payload() { # sev_payload <ctx_pct> <five_hour_pct> <seven_day_pct>
  jq -nc --argjson c "$1" --argjson f "$2" --argjson s "$3" --argjson now "$NOW" '{
    session_id: "sev", transcript_path: "", cwd: "",
    context_window: { total_input_tokens: 0, context_window_size: 0, used_percentage: $c },
    rate_limits: { five_hour: { used_percentage: $f, resets_at: $now },
                   seven_day: { used_percentage: $s, resets_at: $now } } }'
}
# With no cwd the working-directory line drops out entirely, leaving four lines:
# bar, git, cost/tokens, limits.
bar_colour()    { sev_payload "$1" 0 0 | render | sed -n 1p | grep -o '38;5;[0-9]*' | head -1 | cut -d';' -f3; }
limit_colours() { sev_payload 0 "$1" "$2" | render | sed -n 4p | grep -o '38;5;[0-9]*' | cut -d';' -f3 | tr '\n' ' '; }

eq "context 0% is quiet"       "$C_OK"   "$(bar_colour 0)"
eq "context 59% is quiet"      "$C_OK"   "$(bar_colour 59)"
eq "context 60% turns amber"   "$C_WARN" "$(bar_colour 60)"
eq "context 85% is still amber" "$C_WARN" "$(bar_colour 85)"
eq "context 86% turns rose"    "$C_CRIT" "$(bar_colour 86)"
eq "context 100% is rose"      "$C_CRIT" "$(bar_colour 100)"

# The context bar also grades absolute tokens, because a 1M window hides
# long-context territory behind a low percentage. Steps are 256k and 512k.
tok_payload() { # tok_payload <total_input_tokens> <context_window_size>
  jq -nc --argjson t "$1" --argjson w "$2" --argjson now "$NOW" '{
    session_id: "tok", transcript_path: "", cwd: "",
    context_window: { total_input_tokens: $t, context_window_size: $w,
                      used_percentage: (($t / $w) * 100) },
    rate_limits: { five_hour: { used_percentage: 0, resets_at: $now },
                   seven_day: { used_percentage: 0, resets_at: $now } } }'
}
tok_colour() { tok_payload "$1" "$2" | render | sed -n 1p | grep -o '38;5;[0-9]*' | head -1 | cut -d';' -f3; }

# All four sit under 60% of a 1M window, so percent alone would keep them quiet.
eq "255999 tokens is quiet"        "$C_OK"   "$(tok_colour 255999 1000000)"
eq "256000 tokens turns amber"     "$C_WARN" "$(tok_colour 256000 1000000)"
eq "511999 tokens is still amber"  "$C_WARN" "$(tok_colour 511999 1000000)"
eq "512000 tokens turns rose"      "$C_CRIT" "$(tok_colour 512000 1000000)"

# Percent is still graded, so a small window keeps its compaction warning even
# though it can never reach the first token step.
eq "190k of a 200k window is rose" "$C_CRIT" "$(tok_colour 190000 200000)"
eq "130k of a 200k window is amber" "$C_WARN" "$(tok_colour 130000 200000)"
eq "100k of a 200k window is quiet" "$C_OK"   "$(tok_colour 100000 200000)"

# The two windows are graded independently, and the reset timers never colour.
eq "5h rose, 7d amber, both timers at rest" \
  "$C_CRIT $C_DETAIL $C_WARN $C_DETAIL " "$(limit_colours 88 71)"
eq "both windows quiet" \
  "$C_OK $C_DETAIL $C_OK $C_DETAIL " "$(limit_colours 12 4)"
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
  "$(ln_ "$(c $C_BODY '$80.09') $(c $C_DETAIL 1.5k) $(c $C_DETAIL 10) $(c $C_DETAIL 100) $(c $C_PRIMARY 1.6k)")" \
  "$out"
cleanup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
