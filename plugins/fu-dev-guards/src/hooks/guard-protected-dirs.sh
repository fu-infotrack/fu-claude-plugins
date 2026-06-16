#!/usr/bin/env bash
# PreToolUse Write|Edit guard — block edits inside protected directories (main
# checkouts), forcing worktree use. Generalised from EntityPlatform's
# guard-main-dir.sh. Config (fu-tools layered, tool key "dev-guards"):
#   protected_dirs        list of absolute dir roots to protect (empty = guard off)
#   protected_dir_exempt  list of regex; a file_path matching any is allowed
#                         (default: paths under /.claude/, where worktrees live)
# Env overrides (newline-separated, used by tests): PROTECTED_DIRS / PROTECTED_DIR_EXEMPT.

fp=$(jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -n "$fp" ] || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fu_config="$here/../../scripts/fu-config.sh"
fu_get() { [ -f "$fu_config" ] && bash "$fu_config" dev-guards "$1" 2>/dev/null || true; }

[ -z "${PROTECTED_DIRS+x}" ]       && PROTECTED_DIRS="$(fu_get protected_dirs)"
[ -z "${PROTECTED_DIR_EXEMPT+x}" ] && PROTECTED_DIR_EXEMPT="$(fu_get protected_dir_exempt)"
[ -z "$PROTECTED_DIR_EXEMPT" ]     && PROTECTED_DIR_EXEMPT="/\.claude/"

# Nothing configured -> nothing to guard.
[ -n "$PROTECTED_DIRS" ] || exit 0

# Is the target inside a protected root? (prefix match, dir normalised to end in /)
in_protected=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  case "$d" in */) ;; *) d="$d/" ;; esac
  case "$fp" in "$d"*) in_protected=1; break ;; esac
done <<< "$PROTECTED_DIRS"
[ "$in_protected" -eq 1 ] || exit 0

# Exempt carve-outs (worktrees, tooling dirs) are still writable.
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  echo "$fp" | grep -qE "$pat" && exit 0
done <<< "$PROTECTED_DIR_EXEMPT"

echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Main-tracked dir. Use EnterWorktree (name: <branch-name>) first."}}'
exit 2
