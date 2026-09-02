#!/usr/bin/env bash
# Hermetic tests for dispatch.sh. `copilot` and `git` are real-or-stubbed on a
# throwaway PATH; nothing reaches GitHub and no real Copilot run is started.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DISPATCH="$HERE/../scripts/dispatch.sh"
pass=0 fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME/.claude/jobs/abc/tmp" "$SANDBOX/bin" "$SANDBOX/repo"

# A `copilot` stub that records its argv and sleeps, so the process is alive long
# enough for the cmdline check to see it.
cat > "$SANDBOX/bin/copilot" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$COPILOT_ARGV_OUT"
sleep 30
STUB
chmod +x "$SANDBOX/bin/copilot"
export PATH="$SANDBOX/bin:$PATH"
export COPILOT_ARGV_OUT="$SANDBOX/argv.txt"

git init -q "$SANDBOX/repo" 2>/dev/null
git -C "$SANDBOX/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
BASE=$(git -C "$SANDBOX/repo" rev-parse HEAD)

BRIEF="$SANDBOX/brief.md"
printf 'DISTINCTIVE-MARKER-LINE-0001 implement the thing\nmore detail here\n' > "$BRIEF"

echo "dispatch.sh"

# --- argument validation -----------------------------------------------------
out=$("$DISPATCH" 2>&1); check "missing --brief exits 1" "$?" "1"
case "$out" in *"--brief is required"*) ok "missing --brief names the flag";; *) bad "missing --brief names the flag" "$out";; esac

out=$("$DISPATCH" --brief "$BRIEF" 2>&1); check "missing --cwd exits 1" "$?" "1"

out=$("$DISPATCH" --brief "$SANDBOX/nope.md" --cwd "$SANDBOX/repo" 2>&1); check "absent brief exits 1" "$?" "1"

: > "$SANDBOX/empty.md"
out=$("$DISPATCH" --brief "$SANDBOX/empty.md" --cwd "$SANDBOX/repo" 2>&1); check "empty brief exits 1" "$?" "1"
case "$out" in *"is empty"*) ok "empty brief says so";; *) bad "empty brief says so" "$out";; esac

out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --bogus 2>&1); check "unknown flag exits 2" "$?" "2"

# An explicitly-passed flag with an empty value must fail loudly. `--session-id
# "$SID"` with SID unset (uuidgen is absent on some hosts) silently dropped the
# continuation before this check existed.
EMPTY=
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --session-id "$EMPTY" --dry-run 2>&1)
check "empty --session-id exits 1" "$?" "1"
case "$out" in *"--session-id was passed with an empty value"*) ok "empty --session-id is named";; *) bad "empty --session-id is named" "$out";; esac
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --model "$EMPTY" --dry-run 2>&1)
check "empty --model exits 1" "$?" "1"
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --log "$EMPTY" --dry-run 2>&1)
check "empty --log exits 1" "$?" "1"
# The cap has a DEFAULT, so an empty explicit value must not silently fall back to
# it -- that would be the --session-id failure again, one flag over.
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --max-ai-credits "$EMPTY" --dry-run 2>&1)
check "empty --max-ai-credits exits 1" "$?" "1"
case "$out" in *"--max-ai-credits was passed with an empty value"*) ok "empty --max-ai-credits is named";; *) bad "empty --max-ai-credits is named" "$out";; esac
# Omitting the flag entirely stays a valid default, not an error.
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run 2>&1)
check "omitted optional flags still default" "$?" "0"

# --- the measured constraint: no brief under ~/.claude ----------------------
JOBS_BRIEF="$HOME/.claude/jobs/abc/tmp/brief.md"
cp "$BRIEF" "$JOBS_BRIEF"
out=$("$DISPATCH" --brief "$JOBS_BRIEF" --cwd "$SANDBOX/repo" 2>&1)
check "brief under ~/.claude is refused" "$?" "1"
case "$out" in
  *"Copilot cannot read there"*) ok "refusal explains why";;
  *) bad "refusal explains why" "$out";;
esac
case "$out" in
  *"/tmp"*) ok "refusal names the fix";;
  *) bad "refusal names the fix" "$out";;
esac

# A relative path that resolves under ~/.claude must be refused too.
( cd "$HOME/.claude/jobs/abc/tmp" && "$DISPATCH" --brief ./brief.md --cwd "$SANDBOX/repo" >/dev/null 2>&1 )
check "relative path into ~/.claude refused" "$?" "1"

# --- dry run -----------------------------------------------------------------
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run 2>&1)
check "--dry-run exits 0" "$?" "0"
case "$out" in *"--allow-all-tools"*) ok "--allow-all-tools always passed";; *) bad "--allow-all-tools always passed" "$out";; esac
case "$out" in *"--no-color"*) ok "--no-color always passed";; *) bad "--no-color always passed" "$out";; esac
case "$out" in *"-s "*|*"--silent"*) bad "-s/--silent NOT passed" "$out";; *) ok "-s/--silent not passed (it hides the resume handle)";; esac
case "$out" in *"bytes of brief"*) ok "--dry-run elides the brief body";; *) bad "--dry-run elides the brief body" "$out";; esac
# --dry-run exists to show the command that will run, so it must not misreport it.
# The elision branch used to re-print `-p`, yielding `-p -p <N bytes of brief>`.
# Count whole `-p` words. A ' -p ' grep cannot see the second one in "-p -p"
# (matches do not overlap), which made an earlier version of this check vacuous.
np=$(printf '%s\n' "$out" | sed -n 's/^DRY_RUN: //p' | awk '{for(i=1;i<=NF;i++) if($i=="-p") n++} END{print n+0}')
check "--dry-run prints -p exactly once" "$np" "1"
case "$out" in *"--model"*) bad "no --model unless asked" "$out";; *) ok "no --model unless asked";; esac
staged_dry=$(printf '%s\n' "$out" | sed -n 's/^BRIEF: //p')
case "$staged_dry" in /tmp/fu-copilot-*) ok "brief staged into /tmp";; *) bad "brief staged into /tmp" "$staged_dry";; esac
[ -f "$staged_dry" ] && ok "staged brief exists" || bad "staged brief exists" "$staged_dry"
perm=$(stat -c '%a' "$staged_dry" 2>/dev/null); check "staged brief is 644" "$perm" "644"

out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run --model gpt-5.6-luna --session-id dead-beef --context long_context 2>&1)
for want in "--model gpt-5.6-luna" "--session-id dead-beef" "--context long_context"; do
  case "$out" in *"$want"*) ok "passthrough: $want";; *) bad "passthrough: $want" "$out";; esac
done

# --- AI-credit cap ----------------------------------------------------------
# A cap is ON by default: an unattended run is exactly the case where nobody is
# watching the credit footer.
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run 2>&1)
case "$out" in *"--max-ai-credits 100"*) ok "default cap of 100 is passed";; *) bad "default cap of 100 is passed" "$out";; esac

out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run --max-ai-credits 250 2>&1)
case "$out" in *"--max-ai-credits 250"*) ok "explicit cap overrides the default";; *) bad "explicit cap overrides the default" "$out";; esac
case "$out" in *"--max-ai-credits 100"*) bad "override replaces rather than adds" "$out";; *) ok "override replaces rather than adds";; esac

# `off` must omit the flag entirely, not pass a literal 'off' Copilot would reject.
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run --max-ai-credits off 2>&1)
check "--max-ai-credits off exits 0" "$?" "0"
case "$out" in *"--max-ai-credits"*) bad "off omits the flag" "$out";; *) ok "off omits the flag";; esac

# Copilot documents a minimum of 30; below it, Copilot itself dies instantly and
# the reason is invisible. Reject here, where the message can say which minimum.
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run --max-ai-credits 29 2>&1)
check "cap below 30 exits 1" "$?" "1"
case "$out" in *"at least 30"*) ok "sub-minimum cap names the minimum";; *) bad "sub-minimum cap names the minimum" "$out";; esac
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run --max-ai-credits 30 2>&1)
check "cap of exactly 30 is accepted" "$?" "0"
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run --max-ai-credits lots 2>&1)
check "non-numeric cap exits 1" "$?" "1"
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run --max-ai-credits 12.5 2>&1)
check "fractional cap exits 1" "$?" "1"

# Usage statistics are written by Copilot, so the cap can be read against what the
# run actually spent instead of guessed at.
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --dry-run --log "$SANDBOX/u.log" 2>&1)
case "$out" in *"--usage-output-file"*) ok "--usage-output-file always passed";; *) bad "--usage-output-file always passed" "$out";; esac
uf=$(printf '%s\n' "$out" | sed -n 's/^USAGE_FILE: //p')
check "usage file sits beside the log" "$uf" "$SANDBOX/u.usage.json"

# --- real launch (against the stub) -----------------------------------------
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --log "$SANDBOX/run.log" 2>&1)
rc=$?
check "launch exits 0" "$rc" "0"
PID=$(printf '%s\n' "$out" | sed -n 's/^PID: //p')
case "$PID" in ''|*[!0-9]*) bad "PID is numeric" "$PID";; *) ok "PID is numeric";; esac
kill -0 "$PID" 2>/dev/null && ok "process is alive after dispatch returns" || bad "process is alive after dispatch returns"
reached=$(printf '%s\n' "$out" | sed -n 's/^BRIEF_REACHED_PROCESS: //p')
check "brief text confirmed in cmdline" "$reached" "yes"
bl=$(printf '%s\n' "$out" | sed -n 's/^BASELINE_HEAD: //p')
check "BASELINE_HEAD is the pre-run HEAD" "$bl" "$BASE"
uf=$(printf '%s\n' "$out" | sed -n 's/^USAGE_FILE: //p')
check "launch prints USAGE_FILE" "$uf" "$SANDBOX/run.usage.json"

# The brief must reach copilot as prompt TEXT, not as a path.
sleep 1
if grep -qF 'DISTINCTIVE-MARKER-LINE-0001' "$SANDBOX/argv.txt" 2>/dev/null; then
  ok "brief inlined into -p, not passed as a path"
else
  bad "brief inlined into -p, not passed as a path" "$(cat "$SANDBOX/argv.txt" 2>/dev/null)"
fi
if grep -qx -- '--max-ai-credits' "$SANDBOX/argv.txt" 2>/dev/null &&
   grep -qx -- '100' "$SANDBOX/argv.txt" 2>/dev/null; then
  ok "cap reaches the launched process argv"
else
  bad "cap reaches the launched process argv" "$(cat "$SANDBOX/argv.txt" 2>/dev/null)"
fi
kill "$PID" 2>/dev/null

# A log under ~/.claude is allowed -- Copilot cannot read there, but the shell writes it.
out=$("$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" --log "$HOME/.claude/jobs/abc/tmp/ok.log" 2>&1)
check "log under ~/.claude is allowed" "$?" "0"
kill "$(printf '%s\n' "$out" | sed -n 's/^PID: //p')" 2>/dev/null

# --- copilot missing from PATH ----------------------------------------------
out=$(PATH="$SANDBOX/emptybin" "$BASH" "$DISPATCH" --brief "$BRIEF" --cwd "$SANDBOX/repo" 2>&1)
check "missing copilot exits 1" "$?" "1"
case "$out" in *"copilot not on PATH"*) ok "missing copilot says so";; *) bad "missing copilot says so" "$out";; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
