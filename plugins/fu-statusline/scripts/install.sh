#!/usr/bin/env bash
# Install the fu-statusline renderer and point Claude Code's statusLine at it.
#
# statusLine is not a plugin capability, and ${CLAUDE_PLUGIN_ROOT} does not
# expand inside settings.json — so the renderer is copied out of the plugin to a
# stable, version-free path and settings.json is patched to point there.
#
# Idempotent. The displaced statusLine value (if any) is recorded so uninstall
# can put it back.
#
#   install.sh [--force]
#     --force   overwrite a file at the install path that is not ours
set -uo pipefail

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h | --help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'install.sh: unknown option %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH."

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="$PLUGIN_ROOT/statusline.sh"

[ -f "$SRC" ] || die "renderer not found at $SRC"
grep -q 'fu-statusline' "$SRC" || die "$SRC is missing the fu-statusline marker — refusing to install it."

# --- validate settings.json before touching anything --------------------------
if [ -e "$SETTINGS" ]; then
    jq -e . "$SETTINGS" >/dev/null 2>&1 ||
        die "$SETTINGS is not valid JSON. Fix it first; nothing was changed."
fi

# --- copy the renderer --------------------------------------------------------
if [ -e "$TARGET" ] && ! is_our_renderer "$TARGET"; then
    [ "$FORCE" = 1 ] ||
        die "$TARGET exists and is not a fu-statusline renderer. Move it aside, or re-run with --force."
fi

mkdir -p "$INSTALL_DIR" || die "could not create $INSTALL_DIR"
cp "$SRC" "$TARGET.tmp.$$" || die "could not write to $INSTALL_DIR"
chmod 755 "$TARGET.tmp.$$"
mv -f "$TARGET.tmp.$$" "$TARGET" || die "could not install $TARGET"

# --- patch settings.json ------------------------------------------------------
[ -e "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"
cp "$SETTINGS" "$BACKUP" 2>/dev/null

current=$(jq -c '.statusLine // null' "$SETTINGS")

if [ "$current" != "null" ] && ! settings_points_at_us "$SETTINGS"; then
    # Record what we are displacing so uninstall restores it rather than
    # deleting the key. A later reinstall over another foreign value replaces
    # this record — the thing being displaced now is what should come back.
    printf '%s\n' "$current" >"$PREV"
    printf '  previous statusLine recorded in %s\n' "$PREV"
fi

if settings_points_at_us "$SETTINGS"; then
    # Already ours: refresh the path but keep whatever the user tuned.
    new=$(jq --arg cmd "$CMD_PATH" '
        .statusLine = (
            (if (.statusLine | type) == "object" then .statusLine else {} end)
            + { type: "command", command: $cmd }
        )' "$SETTINGS")
else
    new=$(jq --arg cmd "$CMD_PATH" '
        .statusLine = { type: "command", command: $cmd, padding: 0, refreshInterval: 10 }' "$SETTINGS")
fi
write_settings "$SETTINGS" "$new"

printf 'fu-statusline installed.\n'
printf '  renderer   %s\n' "$TARGET"
printf '  statusLine %s\n' "$CMD_PATH"
printf '  snapshot   %s\n' "$BACKUP"
printf 'Takes effect on the next status line refresh; no restart needed.\n'
