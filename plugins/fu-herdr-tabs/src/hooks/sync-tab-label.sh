#!/usr/bin/env bash
# SessionStart + Stop hook — rename this session's Herdr tab to the session title.
#
# Registered on BOTH events, deliberately. SessionStart is what /rename fires, so
# a rename reaches the tab bar in about a second (measured with a 2s-resolution
# sampler across three renames); Stop catches the titles Claude sets for itself
# mid-task. Registered with NO matcher so SessionStart also re-fires on
# clear/compact/resume — a compaction must not strand the tab on a stale name.
#
# All this does is lift `session_id` off the hook payload and hand it to the
# engine: it is tier 2 of the caller resolution, and the only tier that still
# works once $HERDR_PANE_ID has gone stale (which happens whenever a pane is
# re-homed). No session id is not fatal — the engine falls back to syncing every
# agent tab.
#
# Always exits 0. A tab label is cosmetic; failing a turn over one would not be.

sid=""
if command -v jq >/dev/null 2>&1; then
  sid="$(jq -r '.session_id // ""' 2>/dev/null)" || sid=""
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# stdout to /dev/null, not stderr: a SessionStart hook's stdout is injected into
# the session as additional context, so anything printed here would become tokens
# in every session. stderr is left alone — it surfaces only in hook debug output,
# which is exactly where a "jq/herdr missing" note belongs.
bash "$here/../../scripts/herdr-tab-sync.sh" sync --session-id "$sid" >/dev/null

exit 0
