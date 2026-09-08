#!/usr/bin/env bash
# Single entry point for managing the fu-statusline installation.
#
#   config.sh [status]                       report what is installed (default)
#   config.sh install [--force]              install the renderer, patch settings.json
#   config.sh uninstall [--keep-script] [--purge]
#                                            restore the displaced statusLine, remove ours
#
# install and uninstall are dispatched to install.sh / uninstall.sh unchanged —
# this wrapper exists so there is one command to reach for, and so `status` can
# answer "is it on?" without changing anything.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

sub=${1-status}
[ $# -gt 0 ] && shift

case "$sub" in
    install) exec bash "$HERE/install.sh" "$@" ;;
    uninstall) exec bash "$HERE/uninstall.sh" "$@" ;;
    -h | --help | help)
        usage
        exit 0
        ;;
    status) ;;
    *)
        printf 'statusline-config: unknown subcommand %s\n\n' "$sub" >&2
        usage >&2
        exit 2
        ;;
esac

# --- status -------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'statusline-config status: unknown option %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

# shellcheck source=lib.sh
source "$HERE/lib.sh"

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH."

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$HERE/.." && pwd)}"
SRC="$PLUGIN_ROOT/statusline.sh"

installed=no
if [ -e "$TARGET" ]; then
    if is_our_renderer "$TARGET"; then
        if [ -f "$SRC" ] && cmp -s "$SRC" "$TARGET"; then
            installed="yes (matches the plugin copy)"
        else
            installed="yes (differs from the plugin copy — re-run install to refresh)"
        fi
    else
        installed="no (a foreign file sits at the install path)"
    fi
fi
printf 'renderer   %s\n' "$TARGET"
printf '           %s\n' "$installed"

if [ -e "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
    cur=$(jq -r 'if (.statusLine | type) == "string" then .statusLine
                 elif (.statusLine | type) == "object" then (.statusLine.command // "(no command)")
                 else "" end' "$SETTINGS")
    if [ -z "$cur" ]; then
        printf 'statusLine unset in %s\n' "$SETTINGS"
    elif settings_points_at_us "$SETTINGS"; then
        printf 'statusLine %s (ours)\n' "$cur"
        printf '           refreshInterval %s, padding %s\n' \
            "$(jq -r '.statusLine.refreshInterval // "unset"' "$SETTINGS")" \
            "$(jq -r '.statusLine.padding // "unset"' "$SETTINGS")"
    else
        printf 'statusLine %s (not ours — install would displace it)\n' "$cur"
    fi
elif [ -e "$SETTINGS" ]; then
    printf 'statusLine unknown — %s is not valid JSON\n' "$SETTINGS"
else
    printf 'statusLine unset — no %s yet\n' "$SETTINGS"
fi

if [ -s "$PREV" ]; then
    printf 'displaced  %s (restored on uninstall)\n' "$(jq -rc '.' "$PREV" 2>/dev/null)"
fi
[ -d "$CACHE_DIR" ] && printf 'cache      %s\n' "$CACHE_DIR"

exit 0
