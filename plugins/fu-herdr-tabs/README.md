# fu-herdr-tabs

Keeps a [Herdr](https://herdr.dev) tab's label in sync with the Claude session title, so the tab
bar reads `orders-api-bug` / `pr-triage` instead of `1` / `2` / `3`.

Herdr has no built-in for this. `tab` and `terminal_title_stripped` are separate sidebar tokens
and nothing makes the tab label follow the agent (checked against the full `herdr
--default-config`), so it has to be scripted.

## What it does

| Trigger | Covers |
|---|---|
| `SessionStart` hook | `/rename`, and every `clear` / `compact` / `resume` — the tab updates in about a second |
| `Stop` hook | titles Claude sets for itself mid-task |
| `/herdr-tabs start` | everything the hooks cannot see (below) |

The hooks are enough for an ordinary interactive session. The optional background watcher polls
`herdr agent list` and is the only thing that reaches:

- **background sessions attached into a pane** — the process lives under the daemon, so neither
  pane-id nor session-id resolution finds them,
- **non-Claude agents** — codex/copilot/droid/cursor all have Herdr integrations but never fire a
  Claude hook,
- **`--bare` sessions**, or any session with restricted `--setting-sources`, which load no hooks.

## Usage

```
/herdr-tabs                 # status: watcher state + resolved config
/herdr-tabs sync            # one shot, same code path as the hooks
/herdr-tabs start           # background watcher (singleton per machine)
/herdr-tabs stop
```

Or directly: `bash "$CLAUDE_PLUGIN_ROOT/scripts/herdr-tab-sync.sh" status`.

**Pinning.** A tab whose label starts with `*` is left alone, so a hand-named tab survives. Rename
it back to anything else and sync resumes.

## Config

`fu-tools` layered config, under the `herdr-tabs` key:

```jsonc
// ~/.claude/fu-tools/config.json
{
  "herdr-tabs": {
    "max_len": 28,          // truncate labels (28th character becomes an ellipsis)
    "pin_prefix": "*",      // labels starting with this are never touched ("" pins nothing)
    "scope": "auto",        // auto | caller | all — see below
    "watch_interval": 5     // seconds, `start`/`watch` only
  }
}
```

Put these in **user** config, not a project `.claude/.fu-tools.json`: resolution takes the
*nearest* project file only, so a per-repo file would shadow the setting everywhere else.

Every key also has an env override — `HERDR_TABS_MAX_LEN`, `HERDR_TABS_PIN_PREFIX`,
`HERDR_TABS_SCOPE`, `HERDR_TABS_INTERVAL`, `HERDR_TABS_STATE_DIR` — which the test suite drives
the whole plugin through. An unusable value (`max_len: "lots"`, `scope: "sideways"`) falls back to
the default rather than breaking the run.

## How the caller is resolved

`$HERDR_PANE_ID` / `$HERDR_TAB_ID` are captured when the pane starts and go **stale if the pane is
re-homed** — measured live: the env said `w1F:t1` while `herdr tab rename "$HERDR_TAB_ID"` answered
`tab_not_found`, and `herdr pane current --current` failed the same way. So there are three tiers:

1. the agent whose `pane_id` matches `$HERDR_PANE_ID`;
2. else the agent whose `agent_session.value` matches the `session_id` on the hook payload;
3. else **every** agent tab — nothing is lost, since each tab gets its own agent's title.

`scope: "caller"` stops at tier 2 (sync nothing rather than touch another tab); `scope: "all"`
starts at tier 3. The watcher is not a pane, so it always runs at tier 3.

Claude prefixes its title with a status glyph (`◐ ◑ ◒ ◓ ✳ ∙` …) and herdr's own
`terminal_title_stripped` does **not** remove all of them — it strips `✳` but leaves `◐` — so the
glyph set is stripped here. The list is enumerated rather than "strip leading punctuation" on
purpose: a title like `(wip) refactor` has to survive intact.

## Safety

`sync` exits 0 on every path — dead socket, missing `herdr`, unparseable JSON, a tab that cannot be
read. A tab label is cosmetic; failing a turn over one would not be. The hook's stdout is
redirected to `/dev/null` because a `SessionStart` hook's stdout is injected into the session as
context; diagnostics go to stderr, which surfaces only in hook debug output.

Note that `herdr` reports errors as JSON with **exit status 0**
(`{"error":{"code":"tab_not_found"}}`), so `$?` tells you nothing — every call here checks for
`.result` instead.

## Tests

Hermetic — `herdr` is stubbed on `PATH`, `$HOME` and the state dir are throwaway, and the cwd is
moved out of any repo so no `.fu-tools.json` is picked up. Nothing reaches a real socket.

```bash
bash plugins/fu-herdr-tabs/test/tab-sync.test.sh
```

## Dependencies

`herdr` and `jq` on `PATH`. Both missing-either-way is handled: the plugin says so once on stderr
and disables itself.
