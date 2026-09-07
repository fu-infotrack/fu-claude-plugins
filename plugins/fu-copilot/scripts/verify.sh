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
  --usage <path>         Copilot's --usage-output-file JSON. Reported, never
                         graded. The file is CUMULATIVE for the Copilot session,
                         so this prints USAGE_SESSION (whole session) and, when
                         dispatch.sh staged a baseline, USAGE_RUN (this dispatch).
                         The cap is a SESSION cap: compare USAGE_SESSION to it --
                         a session sitting AT the cap was cut short, not finished.
  --session-id <uuid>    SESSION_ID from dispatch.sh. Records this run's totals as
                         the baseline for the next dispatch that resumes the same
                         session. Without it, resumed runs over-report by the
                         whole prior run.

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

cwd= baseline= lossless_from= range= log= usage_json= session_id=
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd=${2:-}; shift 2 ;;
    --baseline) baseline=${2:-}; shift 2 ;;
    --lossless-from) lossless_from=${2:-}; shift 2 ;;
    --range) range=${2:-}; shift 2 ;;
    --log) log=${2:-}; shift 2 ;;
    --usage) usage_json=${2:-}; shift 2 ;;
    --session-id) session_id=${2:-}; shift 2 ;;
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
#
# The file is CUMULATIVE FOR THE COPILOT SESSION, not per dispatch (measured
# 2026-09-07; see dispatch.sh). Two numbers matter and they are not the same one:
# the cap Copilot enforces is a SESSION cap, so USAGE_SESSION is what to compare
# against it -- while "what did this dispatch cost" is USAGE_RUN, the delta over
# the baseline dispatch.sh staged. Printing only the raw file conflates them and
# over-reports every resumed run by the whole prior run.
if [ -n "$usage_json" ]; then
  if [ ! -r "$usage_json" ]; then
    printf '%-16s %s\n' 'USAGE:' "not written (Copilot may have died before it could): $usage_json"
  elif ! command -v jq >/dev/null 2>&1 || ! jq -e . "$usage_json" >/dev/null 2>&1; then
    printf '%-16s %s\n' 'USAGE:' "$(head -c 400 "$usage_json" | tr '\n' ' ')"
    printf '%-16s %s\n' 'USAGE_SCOPE:' "unparsed (no jq, or not valid JSON) -- these totals are SESSION-cumulative, not this run"
  else
    base="${usage_json%.json}.baseline.json"
    # Only monotonic session counters are subtracted. codeChanges is deliberately
    # NOT delta'd: filesModified is a SET, so a file touched by two runs appears
    # once and no subtraction recovers per-run truth. A guessed number is a check
    # that lies, so it is reported as what it is and git stays the authority.
    # aiu is derived AFTER subtracting, never by subtracting two rounded aius --
    # that leaves 1.3400000000000034 where the answer is 1.34.
    raw='{nano_aiu:(.totalNanoAiu//0), premium_requests:(.totalPremiumRequestCost//0), user_requests:(.totalUserRequests//0), api_ms:(.totalApiDurationMs//0)}'
    aiu='. as $x | {aiu:(($x.nano_aiu/1e9)*100|round/100)} + $x'
    printf '%-16s %s\n' 'USAGE_SESSION:' "$(jq -c "$raw | $aiu" "$usage_json")"
    if [ -r "$base" ] && jq -e . "$base" >/dev/null 2>&1; then
      printf '%-16s %s\n' 'USAGE_RUN:' \
        "$(jq -c -s "(.[0]|$raw) as \$n | (.[1]|$raw) as \$p |
             (\$n | to_entries | map(.value -= (\$p[.key]//0)) | from_entries) | $aiu" \
           "$usage_json" "$base")"
      printf '%-16s %s\n' 'USAGE_SCOPE:' "resumed session -- USAGE_RUN is this dispatch, USAGE_SESSION is the whole session (compare THAT to --max-ai-credits)"
    else
      printf '%-16s %s\n' 'USAGE_SCOPE:' "no baseline staged -- USAGE_SESSION is this dispatch only if the session was fresh; a resumed run without a baseline over-reports by the prior run"
    fi
    cc=$(jq -r '.codeChanges // empty | "\(.linesAdded // 0) added / \(.linesRemoved // 0) removed / \(.filesModifiedCount // 0) file(s)"' "$usage_json")
    [ -n "$cc" ] && printf '%-16s %s\n' 'USAGE_CHANGES:' "$cc -- SESSION-cumulative and NOT graded; a resumed read-only run still reports the prior run's files. Use HEAD_MOVED/EMPTY_COMMITS above, not this."
  fi

  # Roll the store forward so the NEXT dispatch of this session has a baseline.
  # Done here rather than in dispatch.sh because only a finished run has totals.
  if [ -n "$session_id" ] && [ -r "$usage_json" ]; then
    store="${FU_COPILOT_STATE:-$HOME/.claude/fu-tools/cache/fu-copilot}/sessions"
    if mkdir -p "$store" 2>/dev/null && cat "$usage_json" > "$store/$session_id.usage.json" 2>/dev/null; then
      chmod 600 "$store/$session_id.usage.json" 2>/dev/null || true
    else
      printf '%-16s %s\n' 'USAGE_STORE:' "could not record baseline for session $session_id -- the next resumed run will over-report"
    fi
  fi
fi

printf '\nVERDICT: %s\n' "$([ "$failed" = 0 ] && echo 'all applicable checks passed' || echo 'one or more checks FAILED -- read the log before believing any summary')"
exit "$failed"
