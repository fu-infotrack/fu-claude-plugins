#!/usr/bin/env bash
# PreToolUse Bash guard — inside a protected (main) checkout, block branch
# switching (git checkout/switch, gh pr checkout) to force worktree use.
# Shares config with guard-protected-dirs.sh but matches the current working
# dir (where the command runs) against protected_dirs.
#   protected_dirs        list of absolute dir roots to protect (empty = guard off)
#   protected_dir_exempt  list of regex; a cwd matching any is allowed
#                         (default: /.claude/, so switching inside a worktree is fine)
# Env overrides (tests): PROTECTED_DIRS / PROTECTED_DIR_EXEMPT / GUARD_CWD.

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Segment + head-match so chained/wrapped forms can't slip past a start-anchor:
#   git fetch && git checkout -b x   env X=1 git switch main   $(git checkout ...)
source "$here/lib/git-guard.sh"
cmd_invokes "$cmd" 'git checkout' 'git switch' 'gh pr checkout' || exit 0

fu_config="$here/../../scripts/fu-config.sh"
fu_get() { [ -f "$fu_config" ] && bash "$fu_config" dev-guards "$1" 2>/dev/null || true; }

[ -z "${PROTECTED_DIRS+x}" ]       && PROTECTED_DIRS="$(fu_get protected_dirs)"
[ -z "${PROTECTED_DIR_EXEMPT+x}" ] && PROTECTED_DIR_EXEMPT="$(fu_get protected_dir_exempt)"
[ -z "$PROTECTED_DIR_EXEMPT" ]     && PROTECTED_DIR_EXEMPT="/\.claude/"

[ -n "$PROTECTED_DIRS" ] || exit 0

cwd="${GUARD_CWD:-$PWD}/"

in_protected=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  case "$d" in */) ;; *) d="$d/" ;; esac
  case "$cwd" in "$d"*) in_protected=1; break ;; esac
done <<< "$PROTECTED_DIRS"
[ "$in_protected" -eq 1 ] || exit 0

while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  echo "$cwd" | grep -qE "$pat" && exit 0
done <<< "$PROTECTED_DIR_EXEMPT"

echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Main-tracked dir. Use EnterWorktree (name: <branch-name>) first."}}'
exit 2
