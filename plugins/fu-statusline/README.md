# fu-statusline

A Claude Code status line renderer in bash + jq. Drop-in replacement for
`npx -y ccstatusline@latest`: same five lines, byte for byte, at **12.3 ms / 11 MB** per render
instead of **605 ms / 103 MB** (49× / 9.4×).

The original re-resolved a 3.3 MB React/Ink bundle from the registry and re-read the entire
session transcript twice, every ten seconds, per session. With nine sessions open that was a
measurable share of machine RAM. `docs/ccstatusline-spec.md` has the full story, the render
contract it reproduces, and the two mechanisms that keep it cheap.

## Install

```
/statusline-install
```

`statusLine` is not a plugin capability, and `${CLAUDE_PLUGIN_ROOT}` does not expand inside
`settings.json`, so the command copies the renderer to a stable path and patches settings:

| Path | Role |
|---|---|
| `~/.claude/statusline/statusline.sh` | the installed renderer (mode 755) |
| `~/.claude/settings.json` → `statusLine.command` | `~/.claude/statusline/statusline.sh` |
| `~/.claude/statusline/previous-statusline.json` | the `statusLine` this displaced, for uninstall |
| `~/.claude/statusline/settings.json.bak` | pre-change snapshot of `settings.json` |
| `~/.cache/cc-statusline/` | render cache: `<session_id>.tok2`, `git2_<escaped-dir>` |

Installing is idempotent, keeps a `padding` / `refreshInterval` you have tuned, and refuses —
changing nothing — if `settings.json` is malformed or a foreign file already sits at the install
path (`--force` overrides only the latter).

```
/statusline-uninstall               # restore the previous statusLine, remove the renderer
/statusline-uninstall --keep-script # leave the renderer on disk
/statusline-uninstall --purge       # also drop the cache and install directory
```

A `statusLine` pointing at something else is never touched.

Both commands are thin wrappers over `scripts/install.sh` and `scripts/uninstall.sh`, which are
runnable directly from a checkout.

## Configuration

None, deliberately. The layout is hardcoded to the five lines and 256-colour codes documented in
the spec; paths derive from `$HOME` (or `$CLAUDE_CONFIG_DIR` and `$XDG_CACHE_HOME` where set).
Refresh cadence is Claude Code's own `statusLine.refreshInterval`.

Making the layout configurable means reading `~/.config/ccstatusline/settings.json` and
reimplementing its widget registry and colour-name mapping in bash — a much larger job that was
considered and declined. That file, if present, is worth keeping as documentation of the spec.

## Dependencies

`jq` and `git`, both already assumed elsewhere in this marketplace. No node, no network.

## Tests

```bash
bash plugins/fu-statusline/test/statusline.test.sh   # render contract
bash plugins/fu-statusline/test/install.test.sh      # settings.json patching
```

The render expectations are worked out by hand from `docs/ccstatusline-spec.md`, not captured
from the implementation, so a formatting regression fails the suite instead of quietly
redefining the format. The install suite runs entirely against a throwaway `$HOME`.
