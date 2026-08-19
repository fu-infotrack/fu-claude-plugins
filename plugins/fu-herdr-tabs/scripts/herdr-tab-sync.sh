#!/usr/bin/env bash
# herdr-tab-sync — keep a Herdr tab's label in sync with the title Claude reports
# for the agent running in that tab's pane.
#
# Herdr has no built-in for this: `tab` and `terminal_title_stripped` are separate
# sidebar tokens and nothing makes the tab label follow the agent, so it has to be
# scripted. Two entry points share this one engine:
#
#   sync   one shot. Fired by the SessionStart/Stop hooks (SessionStart is what
#          /rename triggers, so a rename lands on the tab bar in ~1s; Stop is the
#          backstop for titles Claude sets for itself mid-task).
#   watch  poll `herdr agent list` on an interval. The only thing that reaches
#          (a) background sessions attached into a pane — their process lives
#          under the daemon, so neither pane-id nor session-id resolution finds
#          them, (b) non-Claude agents (codex/copilot/droid/…) which never fire a
#          Claude hook, and (c) sessions started --bare or with restricted
#          --setting-sources, which load no hooks at all.
#
# Never fails a turn: `sync` exits 0 on every path, including a dead socket, a
# missing `herdr`, or malformed JSON.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
TOOL=herdr-tabs

# Every herdr call is a socket round-trip (~20ms measured). The cap is for the
# pathological case of a wedged daemon, not for normal latency — a hook that
# blocks is worse than a tab with a stale name.
CALL_TIMEOUT=5

usage() {
  cat <<'TXT'
herdr-tab-sync — sync Herdr tab labels with agent titles

  sync     [--session-id ID] [--scope auto|caller|all] [--force]   one shot (hook entry point)
  watch    [--interval N]                                          poll forever, foreground
  start    [--interval N]                                          run `watch` in the background
  stop                                                             stop the background watcher
  status                                                           report watcher + resolved config

  -v, --verbose     print each rename
      --max-len N   truncate labels to N characters
TXT
}

# --- config -----------------------------------------------------------------
# fu-tools layered config under the `herdr-tabs` key, env vars winning (the tests
# drive it entirely through the env seam). Note the resolver walks up from $PWD,
# so a nearer .claude/.fu-tools.json shadows a farther one — these keys want to
# apply in every repo, which means USER config (~/.claude/fu-tools/config.json).
cfg() { # cfg <key> <default>
  local v=""
  if [ -f "$HERE/fu-config.sh" ] && command -v jq >/dev/null 2>&1; then
    v="$(bash "$HERE/fu-config.sh" "$TOOL" "$1" 2>/dev/null | head -n1)" || v=""
  fi
  printf '%s' "${v:-$2}"
}

MAX_LEN="${HERDR_TABS_MAX_LEN:-$(cfg max_len 28)}"
# ${VAR-} not ${VAR:-}: an explicitly empty pin prefix means "pin nothing", which
# is a different request from "unset, use the default".
PIN_PREFIX="${HERDR_TABS_PIN_PREFIX-$(cfg pin_prefix '*')}"
SCOPE="${HERDR_TABS_SCOPE:-$(cfg scope auto)}"
INTERVAL="${HERDR_TABS_INTERVAL:-$(cfg watch_interval 5)}"
STATE_DIR="${HERDR_TABS_STATE_DIR:-$HOME/.claude/fu-tools/$TOOL}"

PIDFILE="$STATE_DIR/watch.pid"
LOGFILE="$STATE_DIR/watch.log"

VERBOSE=0
STAMP=0
FORCE=0
SESSION_ID=""

say() {
  [ "$VERBOSE" = 1 ] || return 0
  if [ "$STAMP" = 1 ]; then printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; else printf '%s\n' "$*"; fi
}

# --- herdr ------------------------------------------------------------------
if command -v timeout >/dev/null 2>&1; then TO=(timeout "$CALL_TIMEOUT"); else TO=(); fi

# herdr answers errors as JSON with exit status 0 ({"error":{"code":"tab_not_found"}}),
# so the status tells you nothing — every caller must look for `.result` instead.
hcall() {
  local out
  out="$("${TO[@]+${TO[@]}}" herdr "$@" 2>/dev/null)" || return 0
  case $out in '{'*) printf '%s' "$out" ;; esac
}

in_herdr() { [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_SOCKET_PATH:-}" ]; }

# Which agents' tabs to rename, and what to rename them to. Three-tier resolution,
# because $HERDR_PANE_ID / $HERDR_TAB_ID are captured when the pane starts and go
# STALE if the pane is re-homed — measured live: the env said w1F:t1 while
# `herdr tab rename "$HERDR_TAB_ID"` answered tab_not_found. So: match the caller
# by pane id, else by the session id the hook was handed on stdin, else fall back
# to syncing every agent tab (nothing is lost — each tab gets its own agent's title).
#
# Claude prefixes its title with a status glyph and herdr's own
# terminal_title_stripped does NOT remove all of them (it strips ✳ but leaves ◐),
# so the glyph set is stripped here. It is an enumerated list rather than "leading
# punctuation" on purpose: a title like "(wip) foo" must survive intact.
SELECT_JQ='
def strip_glyphs: sub("^[\\s◐◑◒◓✳∙●○◇◆⏵⚙·•*]+"; "") | sub("\\s+$"; "");
def clip($n): if ($n > 1 and length > $n) then .[0:$n-1] + "…" else . end;
(.result.agents // [])
| ( [ .[] | select($pane != "" and (.pane_id // "") == $pane) ] )            as $bypane
| ( [ .[] | select($sid  != "" and (.agent_session.value // "") == $sid) ] ) as $bysid
| ( if   $scope == "all"        then .
    elif ($bypane | length) > 0 then $bypane
    elif ($bysid  | length) > 0 then $bysid
    elif $scope == "caller"     then []
    else . end )
| .[]
| { tab: (.tab_id // ""), want: ((.terminal_title_stripped // "") | strip_glyphs | clip($max)) }
| select(.tab != "" and .want != "")
| .tab + "\t" + .want
'

sync_once() { # sync_once <session-id> <scope>
  local sid="$1" scope="$2" pane agents tab want got have
  pane="${HERDR_PANE_ID:-}"
  [ "$scope" = all ] && pane=""

  agents="$(hcall agent list)"
  [ -n "$agents" ] || return 0

  while IFS=$'\t' read -r tab want; do
    [ -n "$tab" ] && [ -n "$want" ] || continue

    # Read the tab's current label before writing. `tab get` carries `label`, which
    # is why no workspace/tab enumeration is needed — one call per tab we intend to
    # touch. A tab that cannot be read is left alone rather than blind-renamed.
    got="$(hcall tab get "$tab")"
    [ -n "$got" ] || continue
    printf '%s' "$got" | jq -e '.result.tab' >/dev/null 2>&1 || continue
    have="$(printf '%s' "$got" | jq -r '.result.tab.label // ""' 2>/dev/null)"

    [ "$have" = "$want" ] && continue
    # Opt-out convention: a label the user typed themselves, marked with the pin
    # prefix, outranks whatever the agent is currently calling itself.
    if [ -n "$PIN_PREFIX" ]; then
      case $have in "$PIN_PREFIX"*) continue ;; esac
    fi

    hcall tab rename "$tab" "$want" >/dev/null
    say "renamed $tab: ${have:-<none>} -> $want"
  done < <(printf '%s' "$agents" | jq -r \
              --arg pane "$pane" --arg sid "$sid" --arg scope "$scope" --argjson max "$MAX_LEN" \
              "$SELECT_JQ" 2>/dev/null)
  return 0
}

# --- watcher ----------------------------------------------------------------
# A singleton per machine: ~/.claude is shared across every session and worktree,
# so without the pidfile each new session's `start` would stack another watcher.
watch_pid() {
  local p
  [ -f "$PIDFILE" ] || return 1
  p="$(cat "$PIDFILE" 2>/dev/null)"
  case $p in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  # Guard against pid reuse — a recycled pid belonging to something else must not
  # be reported as running, and must never be killed by `stop`.
  if [ -r "/proc/$p/cmdline" ]; then
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'herdr-tab-sync' || return 1
  fi
  printf '%s' "$p"
}

cmd_watch() {
  # The watcher is not a pane, so caller resolution is meaningless here: it always
  # syncs every agent tab. It also does NOT gate on HERDR_ENV — a daemon may
  # outlive the pane that started it, and the socket answering is the real test.
  local nap=""
  VERBOSE=1; STAMP=1
  # `sleep & wait`, not a bare `sleep`: bash defers a trap until the foreground
  # command finishes, so a plain sleep would make `stop` take up to $INTERVAL
  # seconds to be noticed. `wait` is interruptible, and the trap kills the nap so
  # no orphaned sleep outlives the watcher.
  trap '[ -n "$nap" ] && kill "$nap" 2>/dev/null; exit 0' INT TERM
  say "watching every ${INTERVAL}s (scope=all, max_len=$MAX_LEN)"
  while :; do
    sync_once "" all
    sleep "$INTERVAL" & nap=$!
    wait "$nap"
  done
}

cmd_start() {
  local p
  mkdir -p "$STATE_DIR" 2>/dev/null
  if p="$(watch_pid)"; then echo "herdr-tab-sync: already watching (pid $p)"; return 0; fi
  rm -f "$PIDFILE"
  nohup bash "$SELF" watch --interval "$INTERVAL" >>"$LOGFILE" 2>&1 &
  p=$!
  printf '%s\n' "$p" > "$PIDFILE"
  echo "herdr-tab-sync: watching every ${INTERVAL}s (pid $p, log $LOGFILE)"
}

cmd_stop() {
  local p
  if ! p="$(watch_pid)"; then rm -f "$PIDFILE"; echo "herdr-tab-sync: not running"; return 0; fi
  kill "$p" 2>/dev/null
  rm -f "$PIDFILE"
  echo "herdr-tab-sync: stopped (pid $p)"
}

cmd_status() {
  local p
  if p="$(watch_pid)"; then echo "watcher:  running (pid $p)"; else echo "watcher:  not running"; fi
  if in_herdr; then echo "herdr:    HERDR_ENV=1 socket=${HERDR_SOCKET_PATH:-}"
  else echo "herdr:    not inside a herdr pane"; fi
  echo "pane:     ${HERDR_PANE_ID:-<unset>}"
  echo "scope:    $SCOPE"
  echo "max_len:  $MAX_LEN"
  echo "pin:      ${PIN_PREFIX:-<none>}"
  echo "interval: ${INTERVAL}s"
  echo "log:      $LOGFILE"
}

# --- args -------------------------------------------------------------------
mode=sync
case "${1:-}" in
  sync|watch|start|stop|status) mode="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --scope)      SCOPE="${2:-auto}"; shift 2 ;;
    --interval)   INTERVAL="${2:-5}"; shift 2 ;;
    --max-len)    MAX_LEN="${2:-28}"; shift 2 ;;
    --force)      FORCE=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            shift ;;
  esac
done

# Validated after the flags, so a bad value from config OR from the command line
# lands on the default instead of reaching jq's --argjson (which would abort the
# whole selection) or `sleep` (which would spin).
case $MAX_LEN  in ''|*[!0-9]*) MAX_LEN=28 ;; esac
case $INTERVAL in ''|*[!0-9]*) INTERVAL=5 ;; esac
case $SCOPE    in auto|caller|all) ;; *) SCOPE=auto ;; esac

if ! command -v jq >/dev/null 2>&1 || ! command -v herdr >/dev/null 2>&1; then
  # Loud on stderr, not silent: a silent skip is indistinguishable from "no tabs
  # to rename", and sync would then never happen on this host with no signal that
  # it stopped. stderr, never stdout — a SessionStart hook's stdout is injected
  # into the session as context.
  printf 'herdr-tab-sync: jq and herdr must both be on PATH — tab sync disabled\n' >&2
  exit 0
fi

case $mode in
  sync)
    in_herdr || [ "$FORCE" = 1 ] || exit 0
    sync_once "$SESSION_ID" "$SCOPE"
    exit 0 ;;
  watch)  cmd_watch ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
esac
