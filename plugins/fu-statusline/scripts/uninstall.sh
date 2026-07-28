#!/usr/bin/env bash
# Remove the fu-statusline renderer and restore whatever statusLine it displaced.
#
#   uninstall.sh [--keep-script] [--purge]
#     --keep-script  leave the installed renderer on disk
#     --purge        also delete the render cache and the install directory
#
# A statusLine that is not ours is left untouched.
set -uo pipefail

KEEP=0 PURGE=0
for arg in "$@"; do
    case "$arg" in
        --keep-script) KEEP=1 ;;
        --purge) PURGE=1 ;;
        -h | --help)
            sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'uninstall.sh: unknown option %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH."

# --- settings.json ------------------------------------------------------------
if [ -e "$SETTINGS" ]; then
    jq -e . "$SETTINGS" >/dev/null 2>&1 ||
        die "$SETTINGS is not valid JSON. Fix it first; nothing was changed."

    if settings_points_at_us "$SETTINGS"; then
        if [ -s "$PREV" ] && jq -e . "$PREV" >/dev/null 2>&1; then
            write_settings "$SETTINGS" "$(jq --slurpfile prev "$PREV" '.statusLine = $prev[0]' "$SETTINGS")"
            printf '  restored the previous statusLine\n'
        else
            write_settings "$SETTINGS" "$(jq 'del(.statusLine)' "$SETTINGS")"
            printf '  removed the statusLine setting\n'
        fi
        rm -f "$PREV"
    else
        current_cmd=$(jq -r 'if (.statusLine | type) == "string" then .statusLine else (.statusLine.command // "") end' "$SETTINGS")
        [ -n "$current_cmd" ] &&
            printf '  statusLine points at something else (%s) — left alone.\n' "$current_cmd"
    fi
fi

# --- the renderer -------------------------------------------------------------
if [ "$KEEP" = 0 ] && [ -e "$TARGET" ]; then
    if is_our_renderer "$TARGET"; then
        rm -f "$TARGET"
        printf '  removed %s\n' "$TARGET"
    else
        printf '  %s is not a fu-statusline renderer — left alone.\n' "$TARGET"
    fi
fi

# --- optional cleanup ---------------------------------------------------------
if [ "$PURGE" = 1 ]; then
    case "$CACHE_DIR" in
        */cc-statusline)
            if [ -d "$CACHE_DIR" ]; then
                rm -rf "$CACHE_DIR"
                printf '  removed cache %s\n' "$CACHE_DIR"
            fi
            ;;
    esac
    case "$INSTALL_DIR" in
        */statusline)
            if [ -d "$INSTALL_DIR" ]; then
                rm -rf "$INSTALL_DIR"
                printf '  removed %s\n' "$INSTALL_DIR"
            fi
            ;;
    esac
fi

rmdir "$INSTALL_DIR" 2>/dev/null

printf 'fu-statusline uninstalled.\n'
