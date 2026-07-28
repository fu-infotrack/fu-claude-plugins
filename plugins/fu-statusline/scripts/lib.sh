#!/usr/bin/env bash
# Shared paths and predicates for install.sh / uninstall.sh.
# Every path derives from the environment, which is what lets the test suite run
# against a throwaway $HOME.

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INSTALL_DIR="$CONFIG_DIR/statusline"
TARGET="$INSTALL_DIR/statusline.sh"
SETTINGS="$CONFIG_DIR/settings.json"
PREV="$INSTALL_DIR/previous-statusline.json"
BACKUP="$INSTALL_DIR/settings.json.bak"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cc-statusline"

# The command written into settings.json uses a leading ~ when the target sits
# under $HOME: Claude Code expands it, and it keeps the user name out of the file.
case "$TARGET" in
    "$HOME"/*) CMD_PATH="~/${TARGET#"$HOME"/}" ;;
    *) CMD_PATH="$TARGET" ;;
esac

die() {
    printf 'fu-statusline: %s\n' "$1" >&2
    exit 1
}

# Is this file one of our renderers? The marker comment identifies plugin-managed
# copies; the cache-path assignment additionally recognises a hand-installed
# renderer from before the plugin existed. Both are specific enough that a
# wrapper script merely *invoking* the renderer does not match.
is_our_renderer() {
    [ -f "$1" ] || return 1
    grep -q 'fu-statusline' "$1" 2>/dev/null && return 0
    grep -qF 'CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cc-statusline"' "$1" 2>/dev/null
}

# Does settings.json's statusLine point at our renderer?
settings_points_at_us() { # settings_points_at_us <settings.json>
    local cmd
    cmd=$(jq -r 'if (.statusLine | type) == "string" then .statusLine else (.statusLine.command // "") end' "$1" 2>/dev/null)
    case "$cmd" in
        *"$CMD_PATH"* | *"$TARGET"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Replace settings.json with <json>, refusing to leave anything half-written.
write_settings() { # write_settings <settings.json> <json>
    local file=$1 json=$2
    [ -n "$json" ] || die "failed to build the new settings.json; nothing was changed."
    printf '%s\n' "$json" >"$file.tmp.$$" || die "could not write next to $file"
    jq -e . "$file.tmp.$$" >/dev/null 2>&1 || {
        rm -f "$file.tmp.$$"
        die "generated settings.json was not valid JSON; nothing was changed."
    }
    mv -f "$file.tmp.$$" "$file" || die "could not replace $file"
}
