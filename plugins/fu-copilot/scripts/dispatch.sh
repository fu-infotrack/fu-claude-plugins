#!/usr/bin/env bash
# fu-copilot: launch a detached GitHub Copilot CLI run and print a machine-readable handle.
#
# Every constraint enforced here was measured, not assumed. See docs/DESIGN.md.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: dispatch.sh --brief <file> --cwd <dir> [options]

  --brief <file>       Task brief. REQUIRED. Must not live under ~/.claude
                       (Copilot CLI cannot read there; see docs/DESIGN.md).
  --cwd <dir>          Directory to run Copilot in. REQUIRED.
  --log <path>         Where to write Copilot's output. Default: beside the
                       staged brief in /tmp. May be under ~/.claude (writes work).
  --model <name>       --model passthrough. Default: unset (Copilot's default).
  --session-id <uuid>  --session-id passthrough. Pass the SAME id again to
                       continue that Copilot session instead of starting fresh.
  --context <tier>     --context passthrough: default | long_context.
  --max-ai-credits <n> Session AI-credit cap. Default 100. `off` disables the cap.
                       Copilot's documented minimum is 30 (`copilot help limits`).
                       Final usage is written beside the log as <log>.usage.json.
  --dry-run            Print the resolved command and exit without launching.

Prints one KEY: VALUE per line. Feed PID to `verify.sh wait` and
BASELINE_HEAD to `verify.sh check --baseline`.
USAGE
}

brief= cwd= log= model= session_id= context= dry_run=0 PASSED_FLAGS=
# A cap is the default, not opt-in: an unattended run is exactly the case where
# nobody is watching the footer. See docs/DESIGN.md.
max_ai_credits=100
while [ $# -gt 0 ]; do
  case "$1" in
    --brief|--cwd|--log|--model|--session-id|--context|--max-ai-credits)
      PASSED_FLAGS="$PASSED_FLAGS $1" ;;
  esac
  case "$1" in
    --brief) brief=${2:-}; shift 2 ;;
    --cwd) cwd=${2:-}; shift 2 ;;
    --log) log=${2:-}; shift 2 ;;
    --model) model=${2:-}; shift 2 ;;
    --session-id) session_id=${2:-}; shift 2 ;;
    --context) context=${2:-}; shift 2 ;;
    --max-ai-credits) max_ai_credits=${2:-}; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "dispatch.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "dispatch.sh: $*" >&2; exit 1; }

# An explicitly-passed flag with an empty value is a caller bug, not a default.
# `--session-id "$SID"` with SID unset (uuidgen is absent on some hosts) would
# otherwise silently drop the continuation -- the exact class of silent failure
# this script exists to prevent.
for pair in "brief:$brief" "cwd:$cwd" "log:$log" "model:$model" \
            "session-id:$session_id" "context:$context" \
            "max-ai-credits:$max_ai_credits"; do
  name=${pair%%:*}
  case " $PASSED_FLAGS " in
    *" --$name "*) [ -n "${pair#*:}" ] || die "--$name was passed with an empty value" ;;
  esac
done

[ -n "$brief" ] || die "--brief is required"
[ -n "$cwd" ]   || die "--cwd is required"
[ -f "$brief" ] || die "brief not found: $brief"
[ -s "$brief" ] || die "brief is empty: $brief"
[ -d "$cwd" ]   || die "--cwd is not a directory: $cwd"

# Copilot documents a minimum of 30 AI credits (`copilot help limits`); a smaller
# value is rejected by Copilot itself, which would surface as a run that died
# instantly for no visible reason. Catch it here, where the message can say why.
case "$max_ai_credits" in
  off) : ;;
  ''|*[!0-9]*) die "--max-ai-credits must be a whole number of credits, or 'off': got '$max_ai_credits'" ;;
  *) [ "$max_ai_credits" -ge 30 ] || die "--max-ai-credits must be at least 30 (Copilot's documented minimum); got $max_ai_credits" ;;
esac

command -v copilot >/dev/null 2>&1 || die "copilot not on PATH"

# MEASURED: Copilot CLI cannot read any path under ~/.claude -- every read returns
# "Permission denied and could not request permission from user" -- and it fails
# SILENTLY: a run that could not read its brief inferred there was nothing to do
# and did a no-op force-push while reporting success. Refuse rather than quietly
# stage a copy, so the caller learns the rule instead of leaning on this script.
brief_abs=$(cd "$(dirname "$brief")" && pwd)/$(basename "$brief")
case "$brief_abs" in
  "$HOME"/.claude/*)
    die "brief is under ~/.claude ($brief_abs) -- Copilot cannot read there and fails silently. Write it to /tmp instead." ;;
esac

stamp=$(date -u +%Y%m%dT%H%M%SZ)
staged=$(mktemp "/tmp/fu-copilot-${stamp}-XXXXXX.md") || die "could not stage brief in /tmp"
cat "$brief" > "$staged" || die "could not write staged brief"
chmod 644 "$staged"
: "${log:=${staged%.md}.log}"

# Copilot writes its final usage statistics here as JSON. A cap you cannot measure
# cannot be tuned, and this file is written by Copilot itself rather than reported
# in prose -- the same reason every check in verify.sh reads git or the log.
usage_file="${log%.log}.usage.json"

log_dir=$(dirname "$log")
mkdir -p "$log_dir" 2>/dev/null || true
[ -d "$log_dir" ] || die "log directory does not exist and could not be created: $log_dir"

# MEASURED: pointing Copilot at a brief PATH is not reliable on its own. The proven
# shape reads the brief into the prompt so the instructions are present regardless
# of what Copilot can read. The staged /tmp path is still worth naming in the brief
# as a re-readable copy (see SKILL.md).
brief_text=$(cat "$staged")

set -- --allow-all-tools --no-color --usage-output-file "$usage_file"
[ "$max_ai_credits" != off ] && set -- "$@" --max-ai-credits "$max_ai_credits"
[ -n "$model" ]      && set -- "$@" --model "$model"
[ -n "$session_id" ] && set -- "$@" --session-id "$session_id"
[ -n "$context" ]    && set -- "$@" --context "$context"
set -- "$@" -p "$brief_text"

if [ "$dry_run" = 1 ]; then
  printf 'DRY_RUN: copilot'
  for a in "$@"; do
    # The brief follows its own `-p`, already printed by the previous iteration --
    # so elide only the body here, or the line shows `-p -p <...>`.
    if [ "$a" = "$brief_text" ]; then printf ' <%d bytes of brief>' "${#brief_text}"
    else printf ' %q' "$a"; fi
  done
  printf '\nBRIEF: %s\nLOG: %s\nUSAGE_FILE: %s\n' "$staged" "$log" "$usage_file"
  exit 0
fi

baseline_head=$(git -C "$cwd" rev-parse HEAD 2>/dev/null || echo -)

# MEASURED: runs took 10-113 minutes. The Bash tool caps timeout at 600000 ms, so a
# foreground run is killed on most real tasks. Launch detached, and exec copilot
# DIRECTLY -- no wrapper script -- so the PID is Copilot's own and its /proc cmdline
# can be checked for the brief text below.
cd "$cwd" || die "could not cd to $cwd"
setsid copilot "$@" > "$log" 2>&1 < /dev/null &
pid=$!

# Confirm the brief actually reached the process rather than trusting that it did.
marker=$(printf '%s' "$brief_text" | tr -d '\n' | cut -c1-32)
reached=unknown
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$pid" 2>/dev/null; then reached=process-exited-early; break; fi
  if [ -r "/proc/$pid/cmdline" ]; then
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$marker"; then reached=yes; break; fi
    reached=no
  fi
  sleep 1
done

cat <<EOF
PID: $pid
BRIEF: $staged
LOG: $log
USAGE_FILE: $usage_file
CWD: $cwd
BASELINE_HEAD: $baseline_head
STARTED: $(date -u +%Y-%m-%dT%H:%M:%SZ)
BRIEF_REACHED_PROCESS: $reached
EOF

if [ "$reached" != yes ]; then
  echo "dispatch.sh: brief text not found in the launched process's cmdline (reached=$reached) -- kill $pid and investigate before waiting on it" >&2
  exit 3
fi
