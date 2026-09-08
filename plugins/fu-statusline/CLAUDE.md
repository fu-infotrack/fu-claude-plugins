# fu-statusline — CLAUDE.md

Read this before changing anything under `plugins/fu-statusline/`. Repo-wide rules — worktrees,
the install cache, the `fu-tools` config contract, the three registries, and the full
external-dependency list — live in the root `CLAUDE.md`.

## Design

- **Settings-patching plugin** (`fu-statusline`): `statusLine` is **not** a plugin manifest key, and `${CLAUDE_PLUGIN_ROOT}` does not expand inside the user's `settings.json` — so the renderer cannot be run from the versioned plugin cache. `scripts/install.sh` copies `statusline.sh` to `~/.claude/statusline/` (a stable, version-free path), records the displaced `statusLine` in `previous-statusline.json` so uninstall restores rather than deletes, and rewrites `settings.json` atomically via jq. All scripts are deterministic bash; the command is a thin wrapper. Install/uninstall recognise their own copy by the literal `fu-statusline` marker in the script header — **don't remove that token**. Paths come from `$HOME`/`$CLAUDE_CONFIG_DIR`/`$XDG_CACHE_HOME` only, which is what makes the test suite hermetic; there is deliberately no `fu-tools` config, since the layout is hardcoded.
- **One command, three subcommands** (v0.11.0): `/statusline-config [status|install|uninstall]`, over `scripts/config.sh`. Two commands for a thing installed once was two entries in every session's command list for no gain. `config.sh` is a dispatcher — it `exec`s `install.sh`/`uninstall.sh` **unaltered**, so their contract and the suite that covers it are untouched; only `status` (the no-arg default, read-only) is new code. Keep it that way: put new install behaviour in `install.sh`, not in the dispatcher.

## Tests

`fu-statusline` ships two plain-bash suites — the render contract and the `settings.json`
patching (which also covers the `config.sh` dispatch and `status`). Both are hermetic (`CC_SL_NOW` pins the clock, `XDG_CACHE_HOME` redirects the cache,
the install suite runs against a throwaway `$HOME`):

```bash
bash plugins/fu-statusline/test/statusline.test.sh
bash plugins/fu-statusline/test/install.test.sh
```

`fu-copilot` ships two plain-bash suites — the dispatch contract (argument validation, the
