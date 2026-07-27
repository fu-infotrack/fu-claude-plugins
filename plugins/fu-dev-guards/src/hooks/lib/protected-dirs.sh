#!/usr/bin/env bash
# Shared protected-directory resolution for the dev guards.
#
# Config (fu-tools layered, tool key "dev-guards"):
#   protected_dirs        list of absolute dir roots to protect (empty = guard off)
#   protected_dir_exempt  list of regex; a path matching any is allowed
#                         (default: /.claude/, where worktrees live)
# Env overrides (newline-separated, used by tests): PROTECTED_DIRS / PROTECTED_DIR_EXEMPT.
#
# guard-protected-dirs.sh and guard-protected-checkout.sh still inline this same
# logic; migrating them onto these helpers is a follow-up. Keep the behaviour
# identical in the meantime — a path judged protected by one must be judged
# protected by all.

pd_load() {
  local libdir fu_config
  libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fu_config="$libdir/../../../scripts/fu-config.sh"
  _pd_get() { [ -f "$fu_config" ] && bash "$fu_config" dev-guards "$1" 2>/dev/null || true; }

  [ -z "${PROTECTED_DIRS+x}" ]       && PROTECTED_DIRS="$(_pd_get protected_dirs)"
  [ -z "${PROTECTED_DIR_EXEMPT+x}" ] && PROTECTED_DIR_EXEMPT="$(_pd_get protected_dir_exempt)"
  [ -z "$PROTECTED_DIR_EXEMPT" ]     && PROTECTED_DIR_EXEMPT="/\.claude/"
  return 0
}

# pd_is_protected <absolute path>  -> 0 when the path is inside a protected root
# and not exempt. Pass directories with a trailing slash.
pd_is_protected() {
  local p=$1 d pat hit=1
  [ -n "${PROTECTED_DIRS:-}" ] || return 1

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in */) ;; *) d="$d/" ;; esac
    case "$p" in "$d"*) hit=0; break ;; esac
  done <<< "$PROTECTED_DIRS"
  [ "$hit" -eq 0 ] || return 1

  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    printf '%s' "$p" | grep -qE "$pat" && return 1
  done <<< "$PROTECTED_DIR_EXEMPT"

  return 0
}
