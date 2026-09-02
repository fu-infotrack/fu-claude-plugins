#!/usr/bin/env bash
# fu-copilot: wait on a dispatched Copilot run, then verify what it actually did.
#
# The premise: a model's self-report is not a completion signal. Measured three
# times in one session -- agents reporting before their run finished, Copilot
# claiming success on a no-op force-push, a reviewer stopping mid-thought after
# 214k tokens. Every check here reads git or the log, never a summary.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: verify.sh wait  <pid> [--poll <seconds>] [--timeout <seconds>]
       verify.sh check --cwd <dir> [options]

wait   Block until the process exits. Uses `kill -0 <pid>`, never a pgrep
       pattern -- parallel Copilot runs across worktrees match each other's
       patterns. Prints ELAPSED and EXITED.

check  Report on what the run did. Options:
  --cwd <dir>            Repo to inspect. REQUIRED.
  --baseline <sha>       BASELINE_HEAD from dispatch.sh. Enables HEAD_MOVED.
  --lossless-from <sha>  Pre-run state; asserts `git diff <sha>..HEAD` is empty.
  --range <range>        Commit range to scan for empty commits, e.g. main..HEAD.
  --log <path>           Copilot's output log; scanned for known failure strings.
  --usage <path>         Copilot's --usage-output-file JSON; printed verbatim.
                         Read it against the cap dispatch.sh passed: a run whose
                         credits used sit AT the cap was cut short, not finished.

check exits 0 if every applicable check passed, 1 if any FAILed.
USAGE
}

die() { echo "verify.sh: $*" >&2; exit 2; }

cmd=${1:-}
[ -n "$cmd" ] || { usage >&2; exit 2; }
shift || true

case "$cmd" in
  -h|--help) usage; exit 0 ;;
  wait)
    pid=${1:-}; shift || true
    poll=15 timeout=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --poll) poll=${2:-15}; shift 2 ;;
        --timeout) timeout=${2:-0}; shift 2 ;;
        *) die "wait: unknown argument: $1" ;;
      esac
    done
    case "$pid" in ''|*[!0-9]*) die "wait: <pid> must be numeric, got: '$pid'" ;; esac
    start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$timeout" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
        echo "ELAPSED: $(( $(date +%s) - start ))s"
        echo "EXITED: no -- still running at timeout"
        exit 1
      fi
      sleep "$poll"
    done
    echo "ELAPSED: $(( $(date +%s) - start ))s"
    echo "EXITED: yes"
    exit 0
    ;;
  check) : ;;
  *) die "unknown subcommand: $cmd" ;;
esac

cwd= baseline= lossless_from= range= log= usage_json=
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd=${2:-}; shift 2 ;;
    --baseline) baseline=${2:-}; shift 2 ;;
    --lossless-from) lossless_from=${2:-}; shift 2 ;;
    --range) range=${2:-}; shift 2 ;;
    --log) log=${2:-}; shift 2 ;;
    --usage) usage_json=${2:-}; shift 2 ;;
    *) die "check: unknown argument: $1" ;;
  esac
done
[ -n "$cwd" ] || die "check: --cwd is required"
[ -d "$cwd" ] || die "check: not a directory: $cwd"

g() { git -C "$cwd" "$@"; }
g rev-parse --git-dir >/dev/null 2>&1 || die "check: not a git repository: $cwd"

failed=0
pass() { printf '%-16s PASS  %s\n' "$1:" "${2-}"; }
fail() { printf '%-16s FAIL  %s\n' "$1:" "${2-}"; failed=1; }
skip() { printf '%-16s SKIP  %s\n' "$1:" "${2-}"; }

head_now=$(g rev-parse HEAD 2>/dev/null || echo -)
printf '%-16s %s\n' 'HEAD:' "$head_now"

# 1. Did anything happen at all? The no-op force-push failure reported success
#    while HEAD never moved, so this is the headline check.
head_moved=unknown
if [ -n "$baseline" ]; then
  if [ "$head_now" != "$baseline" ]; then
    head_moved=yes; pass HEAD_MOVED "$baseline -> $head_now"
  else
    head_moved=no;  fail HEAD_MOVED "still at $baseline -- the run changed nothing"
  fi
else
  skip HEAD_MOVED "no --baseline given"
fi

# 2. Empty commits. Reported per commit rather than as a count, because "which
#    one" is the actionable part.
if [ -n "$range" ]; then
  empties=$(g log --format='%H %s' --shortstat "$range" 2>/dev/null | awk '
    /^[0-9a-f]{40} / { if (sha != "" && !seen) print sha " " subj; sha=$1; subj=substr($0, 42); seen=0; next }
    /files? changed/ { seen=1 }
    END { if (sha != "" && !seen) print sha " " subj }
  ')
  if [ -z "$empties" ]; then
    n=$(g rev-list --count "$range" 2>/dev/null || echo 0)
    pass EMPTY_COMMITS "none in $range ($n commits)"
  else
    fail EMPTY_COMMITS "$(printf '%s\n' "$empties" | wc -l | tr -d ' ') empty in $range"
    printf '%s\n' "$empties" | sed 's/^/                       /'
  fi
else
  skip EMPTY_COMMITS "no --range given"
fi

# 3. Losslessness -- and say plainly when it is vacuous, which is the trap: this
#    check passes trivially when nothing happened.
if [ -n "$lossless_from" ]; then
  if ! g cat-file -e "${lossless_from}^{commit}" 2>/dev/null; then
    fail LOSSLESS "unknown commit: $lossless_from"
  elif g diff --quiet "$lossless_from" HEAD 2>/dev/null; then
    if [ "$head_moved" = no ]; then
      fail LOSSLESS "diff empty but HEAD never moved -- vacuous, means nothing here"
    else
      pass LOSSLESS "git diff $lossless_from..HEAD is empty"
    fi
  else
    fail LOSSLESS "$(g diff --shortstat "$lossless_from" HEAD 2>/dev/null | sed 's/^ *//')"
  fi
else
  skip LOSSLESS "no --lossless-from given"
fi

# 4. Uncommitted leftovers.
dirty=$(g status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [ "$dirty" = 0 ]; then pass WORKTREE_CLEAN; else fail WORKTREE_CLEAN "$dirty uncommitted path(s)"; fi

# 5. Known failure strings in Copilot's own log. A permission denial is BLOCKING:
#    Copilot proceeds on a guess rather than stopping.
if [ -n "$log" ]; then
  if [ ! -r "$log" ]; then
    fail LOG "not readable: $log"
  else
    bytes=$(wc -c < "$log" | tr -d ' ')
    if grep -qF 'Permission denied and could not request permission' "$log" 2>/dev/null; then
      fail LOG_PERMISSION "Copilot hit a read it could not request -- treat as BLOCKING, it will have guessed"
    else
      pass LOG_PERMISSION
    fi
    printf '%-16s %s bytes -- %s\n' 'LOG:' "$bytes" "$log"
    resume=$(grep -oE 'copilot --resume=[0-9a-f-]+' "$log" 2>/dev/null | tail -1)
    [ -n "$resume" ] && printf '%-16s %s\n' 'RESUME:' "$resume"
  fi
else
  skip LOG_PERMISSION "no --log given"
fi

# Reported, never graded. The AI-credit cap is a SOFT cap -- Copilot observes usage
# only after a response returns, so a capped run stops between model calls with its
# work half-done and every git check still passing. That is not something this
# script can decide for you; it is something you must read. Credits used sitting at
# the cap means the run was cut short.
if [ -n "$usage_json" ]; then
  if [ ! -r "$usage_json" ]; then
    printf '%-16s %s\n' 'USAGE:' "not written (Copilot may have died before it could): $usage_json"
  elif command -v jq >/dev/null 2>&1 && jq -e . "$usage_json" >/dev/null 2>&1; then
    printf '%-16s %s\n' 'USAGE:' "$(jq -c . "$usage_json")"
  else
    printf '%-16s %s\n' 'USAGE:' "$(head -c 400 "$usage_json" | tr '\n' ' ')"
  fi
fi

printf '\nVERDICT: %s\n' "$([ "$failed" = 0 ] && echo 'all applicable checks passed' || echo 'one or more checks FAILED -- read the log before believing any summary')"
exit "$failed"
