#!/usr/bin/env bash
# Tests for the Herdr tab-label sync engine and its hook wrapper.
# No framework — run: bash plugins/fu-herdr-tabs/test/tab-sync.test.sh
#
# Hermetic: `herdr` is stubbed on PATH (canned JSON in, a call log out), $HOME is
# a throwaway so fu-config.sh resolves against nothing, and the cwd is moved out
# of the repo so no ancestor .claude/.fu-tools.json is picked up. Nothing reaches
# a real Herdr socket.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/../scripts/herdr-tab-sync.sh"
HOOK="$HERE/../src/hooks/sync-tab-label.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# --- the herdr stub ---------------------------------------------------------
# Answers `agent list` from $STUB/agents.json, `tab get <id>` from
# $STUB/tab-<id>.json (falling back to herdr's real tab_not_found error shape,
# which it returns with exit status 0 — the reason the engine looks for .result
# rather than trusting $?), and appends every rename to $STUB/renames.log.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/calls.log"
case "${1:-} ${2:-}" in
  "agent list") cat "$STUB/agents.json" 2>/dev/null || printf '{"error":{"code":"no_server"}}' ;;
  "tab get")
    f="$STUB/tab-${3//:/_}.json"
    if [ -f "$f" ]; then cat "$f"
    else printf '{"id":"cli:tab:get","error":{"code":"tab_not_found","message":"tab %s not found"}}' "$3"; fi ;;
  "tab rename")
    printf '%s\t%s\n' "$3" "$4" >> "$STUB/renames.log"
    printf '{"id":"cli:tab:rename","result":{"tab":{"tab_id":"%s","label":"%s"}}}' "$3" "$4" ;;
  *) printf '{"error":{"code":"unknown"}}' ;;
esac
STUB
chmod +x "$BIN/herdr"

STUB="$TMP/stub"; mkdir -p "$STUB"
export STUB
export PATH="$BIN:$PATH"
export HOME="$TMP/home"; mkdir -p "$HOME"
export HERDR_TABS_STATE_DIR="$TMP/state"
cd "$TMP" || exit 1

SID_A=aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa
SID_B=bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb

# agent <pane> <tab> <session-id> <title>
agent() {
  printf '{"agent":"claude","agent_session":{"kind":"id","value":"%s"},"pane_id":"%s","tab_id":"%s","terminal_title_stripped":"%s","workspace_id":"w1"}' \
    "$3" "$1" "$2" "$4"
}
agents() { printf '{"id":"cli:agent:list","result":{"agents":[%s],"type":"agent_list"}}' "$(IFS=,; echo "$*")" > "$STUB/agents.json"; }
tab()    { printf '{"id":"cli:tab:get","result":{"tab":{"tab_id":"%s","label":"%s"},"type":"tab_info"}}' "$1" "$2" > "$STUB/tab-${1//:/_}.json"; }

reset() { rm -f "$STUB/renames.log" "$STUB/calls.log" "$STUB"/tab-*.json "$STUB/agents.json"; }

# run <args...> -> RC / OUT / ERR, with the caller's pane/env already set
run() {
  OUT=$(bash "$ENGINE" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
}
renames() { cat "$STUB/renames.log" 2>/dev/null; }
renamed_to() { grep -qP "^\Q$1\E\t\Q$2\E$" "$STUB/renames.log" 2>/dev/null; }

export HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/fake.sock

echo "== outside a herdr pane, sync is a no-op =="

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'anything')"; tab w1:t1 old
HERDR_ENV= run sync --session-id "$SID_A"
[ "$RC" -eq 0 ] && ok || bad "no-herdr sync should exit 0 (got $RC)"
[ ! -s "$STUB/calls.log" ] && ok || bad "HERDR_ENV unset should make no herdr calls: $(cat "$STUB/calls.log" 2>/dev/null)"

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'anything')"; tab w1:t1 old
HERDR_SOCKET_PATH= run sync --session-id "$SID_A"
[ ! -s "$STUB/calls.log" ] && ok || bad "no socket path should make no herdr calls"

# --force is the escape hatch that lets the rest of the suite exercise the guard
# separately from the logic it guards.
reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'anything')"; tab w1:t1 old
HERDR_ENV= HERDR_PANE_ID=w1:p1 run sync --force --session-id "$SID_A"
renamed_to w1:t1 anything && ok || bad "--force should sync even with HERDR_ENV unset"

echo "== tier 1: the caller is resolved by pane id =="

reset
agents "$(agent w1:p1 w1:t1 "$SID_A" 'mine')" "$(agent w2:p1 w2:t1 "$SID_B" 'theirs')"
tab w1:t1 old; tab w2:t1 old
HERDR_PANE_ID=w1:p1 run sync --session-id "$SID_A"
renamed_to w1:t1 mine && ok || bad "caller's tab should be renamed"
[ "$(renames | wc -l)" -eq 1 ] && ok || bad "only the caller's tab should be touched: $(renames)"

echo "== tier 2: a stale pane id falls through to the session id =="

# The live failure this exists for: the env still says w1F:p1 after the pane was
# re-homed, and herdr answers tab_not_found for it.
reset
agents "$(agent w1:p1 w1:t1 "$SID_A" 'mine')" "$(agent w2:p1 w2:t1 "$SID_B" 'theirs')"
tab w1:t1 old; tab w2:t1 old
HERDR_PANE_ID=w1F:p1 run sync --session-id "$SID_A"
renamed_to w1:t1 mine && ok || bad "stale pane id should fall back to session-id match"
[ "$(renames | wc -l)" -eq 1 ] && ok || bad "session-id match should still touch one tab: $(renames)"

echo "== tier 3: neither resolves, so every agent tab is synced =="

reset
agents "$(agent w1:p1 w1:t1 "$SID_A" 'one')" "$(agent w2:p1 w2:t1 "$SID_B" 'two')"
tab w1:t1 old; tab w2:t1 old
HERDR_PANE_ID=nope:p9 run sync --session-id unknown-session
renamed_to w1:t1 one && renamed_to w2:t1 two && ok || bad "unresolved caller should sync all tabs: $(renames)"

echo "== scope overrides the fallback in both directions =="

reset
agents "$(agent w1:p1 w1:t1 "$SID_A" 'one')" "$(agent w2:p1 w2:t1 "$SID_B" 'two')"
tab w1:t1 old; tab w2:t1 old
HERDR_PANE_ID=nope:p9 run sync --scope caller --session-id unknown-session
[ -z "$(renames)" ] && ok || bad "scope=caller must not fall back to all tabs: $(renames)"

reset
agents "$(agent w1:p1 w1:t1 "$SID_A" 'one')" "$(agent w2:p1 w2:t1 "$SID_B" 'two')"
tab w1:t1 old; tab w2:t1 old
HERDR_PANE_ID=w1:p1 run sync --scope all --session-id "$SID_A"
[ "$(renames | wc -l)" -eq 2 ] && ok || bad "scope=all should sync every tab even when the caller resolves: $(renames)"

# Config, not just flags — and an unusable value must fall back rather than break
# the jq selection outright.
reset
agents "$(agent w1:p1 w1:t1 "$SID_A" 'one')" "$(agent w2:p1 w2:t1 "$SID_B" 'two')"
tab w1:t1 old; tab w2:t1 old
HERDR_PANE_ID=w1:p1 HERDR_TABS_SCOPE=all run sync --session-id "$SID_A"
[ "$(renames | wc -l)" -eq 2 ] && ok || bad "scope should be settable from config/env: $(renames)"

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'one')"; tab w1:t1 old
HERDR_PANE_ID=w1:p1 HERDR_TABS_SCOPE=sideways run sync --session-id "$SID_A"
renamed_to w1:t1 one && ok || bad "a nonsense scope should fall back to auto, not break the run"

echo "== status glyphs are stripped, other leading punctuation is not =="

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" '◐ herdr')"; tab w1:t1 old
HERDR_PANE_ID=w1:p1 run sync
renamed_to w1:t1 herdr && ok || bad "leading ◐ should be stripped: $(renames)"

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" '✳ hoot-t3')"; tab w1:t1 old
HERDR_PANE_ID=w1:p1 run sync
renamed_to w1:t1 hoot-t3 && ok || bad "leading ✳ should be stripped: $(renames)"

# The reason the glyph list is enumerated instead of "strip leading punctuation".
reset; agents "$(agent w1:p1 w1:t1 "$SID_A" '(wip) refactor')"; tab w1:t1 old
HERDR_PANE_ID=w1:p1 run sync
renamed_to w1:t1 '(wip) refactor' && ok || bad "ordinary punctuation must survive: $(renames)"

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" '◐   ')"; tab w1:t1 old
HERDR_PANE_ID=w1:p1 run sync
[ -z "$(renames)" ] && ok || bad "a title that strips to nothing should not rename: $(renames)"

echo "== labels are truncated to max_len, ellipsis included =="

long='abcdefghijklmnopqrstuvwxyz0123456789'
reset; agents "$(agent w1:p1 w1:t1 "$SID_A" "$long")"; tab w1:t1 old
HERDR_PANE_ID=w1:p1 run sync
got=$(renames | cut -f2)
[ "${#got}" -eq 28 ] && ok || bad "default max_len should be 28 (got ${#got}: $got)"
[ "$got" = "abcdefghijklmnopqrstuvwxyz0…" ] && ok || bad "truncation should end in an ellipsis: $got"

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" "$long")"; tab w1:t1 old
HERDR_PANE_ID=w1:p1 HERDR_TABS_MAX_LEN=10 run sync
got=$(renames | cut -f2)
[ "$got" = "abcdefghi…" ] && ok || bad "max_len should be configurable (got $got)"

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" "$long")"; tab w1:t1 old
HERDR_PANE_ID=w1:p1 HERDR_TABS_MAX_LEN=lots run sync
got=$(renames | cut -f2)
[ "${#got}" -eq 28 ] && ok || bad "a non-numeric max_len should fall back to 28 (got $got)"

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'short')"; tab w1:t1 old
HERDR_PANE_ID=w1:p1 run sync
renamed_to w1:t1 short && ok || bad "a short title should pass through unchanged"

echo "== pinned labels are left alone =="

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'auto')"; tab w1:t1 '*hand-named'
HERDR_PANE_ID=w1:p1 run sync
[ -z "$(renames)" ] && ok || bad "a label starting with the pin prefix must survive: $(renames)"

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'auto')"; tab w1:t1 '*hand-named'
HERDR_PANE_ID=w1:p1 HERDR_TABS_PIN_PREFIX='#' run sync
renamed_to w1:t1 auto && ok || bad "a different pin prefix should unpin the * label: $(renames)"

# An empty pin prefix means "pin nothing" — it must not glob-match every label
# and silently disable the plugin.
reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'auto')"; tab w1:t1 '*hand-named'
HERDR_PANE_ID=w1:p1 HERDR_TABS_PIN_PREFIX= run sync
renamed_to w1:t1 auto && ok || bad "an empty pin prefix should pin nothing: $(renames)"

echo "== no pointless writes =="

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'same')"; tab w1:t1 same
HERDR_PANE_ID=w1:p1 run sync
[ -z "$(renames)" ] && ok || bad "an already-correct label should not be rewritten"

# tab get answering tab_not_found (exit status still 0) must not become a blind
# rename of a tab that may not exist.
reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'ghost')"
HERDR_PANE_ID=w1:p1 run sync
[ -z "$(renames)" ] && ok || bad "an unreadable tab should be skipped, not renamed"
grep -q '^tab get' "$STUB/calls.log" && ok || bad "the engine should still have tried to read the tab"

echo "== broken environments never fail the turn =="

reset  # no agents.json at all -> stub returns an error object
HERDR_PANE_ID=w1:p1 run sync
[ "$RC" -eq 0 ] && ok || bad "an error from agent list should still exit 0 (got $RC)"
[ -z "$(renames)" ] && ok || bad "an error from agent list should rename nothing"

reset; printf 'not json at all' > "$STUB/agents.json"
HERDR_PANE_ID=w1:p1 run sync
[ "$RC" -eq 0 ] && ok || bad "unparseable agent list should still exit 0 (got $RC)"
[ -z "$(renames)" ] && ok || bad "unparseable agent list should rename nothing"

reset; printf '{"result":{"agents":[]}}' > "$STUB/agents.json"
HERDR_PANE_ID=w1:p1 run sync
[ "$RC" -eq 0 ] && ok || bad "an empty agent list should exit 0"

# herdr missing entirely: say so on stderr (a silent skip is indistinguishable
# from "nothing to rename"), print nothing on stdout, still exit 0.
reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'one')"; tab w1:t1 old
OUT=$(PATH="/usr/bin:/bin" HERDR_PANE_ID=w1:p1 "$BASH" "$ENGINE" sync 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
[ "$RC" -eq 0 ] && ok || bad "a missing herdr should still exit 0 (got $RC)"
[ -z "$OUT" ] && ok || bad "a missing herdr must print nothing to stdout (got <$OUT>)"
grep -q 'tab sync disabled' <<<"$ERR" && ok || bad "a missing herdr should say so on stderr (got <$ERR>)"

echo "== the hook wrapper =="

reset
agents "$(agent w1:p1 w1:t1 "$SID_A" 'from-hook')" "$(agent w2:p1 w2:t1 "$SID_B" 'other')"
tab w1:t1 old; tab w2:t1 old
# No usable pane id, so this only passes if the wrapper actually lifted
# session_id off the payload and handed it to the engine.
OUT=$(HERDR_PANE_ID=stale:p9 bash "$HOOK" <<<"{\"session_id\":\"$SID_A\"}" 2>"$TMP/err"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "hook should exit 0 (got $RC)"
renamed_to w1:t1 from-hook && ok || bad "hook should pass session_id through: $(renames)"
[ "$(renames | wc -l)" -eq 1 ] && ok || bad "hook should resolve one tab, not fall back to all"

# A SessionStart hook's stdout is injected into the session as context, so it has
# to stay empty even when the engine is chatty.
reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'from-hook')"; tab w1:t1 old
OUT=$(HERDR_PANE_ID=w1:p1 bash "$HOOK" <<<"{\"session_id\":\"$SID_A\"}" 2>/dev/null)
[ -z "$OUT" ] && ok || bad "hook stdout must stay empty (got <$OUT>)"

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'from-hook')"; tab w1:t1 old
OUT=$(HERDR_PANE_ID=w1:p1 bash "$HOOK" <<<'{ this is not json' 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok || bad "malformed hook payload should still exit 0 (got $RC)"
renamed_to w1:t1 from-hook && ok || bad "a malformed payload should still sync by pane id"

OUT=$(bash "$HOOK" </dev/null 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok || bad "empty stdin should still exit 0 (got $RC)"

echo "== watcher lifecycle =="

reset; agents "$(agent w1:p1 w1:t1 "$SID_A" 'watched')"; tab w1:t1 old
run status
grep -q 'watcher:  not running' <<<"$OUT" && ok || bad "status should report a stopped watcher: $OUT"

run stop
grep -q 'not running' <<<"$OUT" && ok || bad "stop with no watcher should be a clean no-op: $OUT"
[ "$RC" -eq 0 ] && ok || bad "stop with no watcher should exit 0"

run start --interval 1
[ -f "$HERDR_TABS_STATE_DIR/watch.pid" ] && ok || bad "start should write a pidfile"
WPID=$(cat "$HERDR_TABS_STATE_DIR/watch.pid" 2>/dev/null)
kill -0 "$WPID" 2>/dev/null && ok || bad "start should leave a live process (pid $WPID)"

# The singleton guard: ~/.claude is shared by every session, so a second start
# must adopt the running watcher rather than stack another one.
run start --interval 1
grep -q 'already watching' <<<"$OUT" && ok || bad "a second start should not stack a watcher: $OUT"
[ "$(cat "$HERDR_TABS_STATE_DIR/watch.pid")" = "$WPID" ] && ok || bad "the pidfile should still hold the first pid"

run status
grep -q "running (pid $WPID)" <<<"$OUT" && ok || bad "status should report the running watcher: $OUT"

# The watcher syncs on its own, with no pane and no session id.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$STUB/renames.log" ] && break
  sleep 0.3
done
renamed_to w1:t1 watched && ok || bad "the watcher should sync tabs on its own: $(renames)"

run stop
grep -q "stopped (pid $WPID)" <<<"$OUT" && ok || bad "stop should report the pid it killed: $OUT"
[ ! -f "$HERDR_TABS_STATE_DIR/watch.pid" ] && ok || bad "stop should clear the pidfile"
# Bounded, but short on purpose: the watcher naps with `sleep & wait` precisely so
# a TERM is acted on immediately rather than at the end of the current interval.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$WPID" 2>/dev/null || break
  sleep 0.2
done
kill -0 "$WPID" 2>/dev/null && bad "stop should have killed the watcher (pid $WPID still alive)" || ok

# A pidfile left behind by a crash — or holding a pid since recycled by something
# else — must read as "not running", and must never get that stranger killed.
printf '%s\n' "$$" > "$HERDR_TABS_STATE_DIR/watch.pid"
run status
grep -q 'watcher:  not running' <<<"$OUT" && ok || bad "a pid that is not a watcher should read as not running: $OUT"
run stop
kill -0 "$$" 2>/dev/null && ok || bad "stop must not kill an unrelated process holding a recycled pid"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
