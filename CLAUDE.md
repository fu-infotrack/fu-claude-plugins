# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **personal Claude Code plugin marketplace** — not an application. Each plugin under `plugins/` is a self-contained extension (skill, command, agents, hooks, scripts, and/or MCP server) that installs at user scope. There is no build step and no `package.json`; the "product" is the plugin directories plus the marketplace manifest.

## Repository layout

- `.claude-plugin/marketplace.json` — the marketplace registry. **Every plugin must be listed here** (`name`, `source`, `description`) or it cannot be installed. The marketplace `source` is a local `directory` pointing at this repo (see `~/.claude/plugins/known_marketplaces.json`).
- `plugins/<name>/.claude-plugin/plugin.json` — per-plugin manifest. The manifest's component keys (`commands`, `skills`, `hooks`, `userConfig`, etc.) declare what the plugin contributes.
- All plugins are prefixed `fu-` for provenance.

## Editing → testing a plugin (the install cache gotcha)

Installed plugins are **copied** to `~/.claude/plugins/cache/fu-claude-plugins/<plugin>/<version>/`. Editing files in this repo does **not** auto-sync to the running session. After changing a plugin:

```bash
claude plugin validate plugins/<name>              # check manifest
claude plugin marketplace update fu-claude-plugins # re-index the local marketplace
claude plugin install fu-<name>@fu-claude-plugins  # reinstall into the cache
```

For a quick single-file test, you can `cp` the changed file straight into the cache path, but the full reinstall is the correct path. Plugin **hooks load at session start** — they take effect on the next session, not mid-session. When adding a new plugin, edit `marketplace.json` first, then `marketplace update` before `install`.

## Committing here triggers this repo's own `fu-dev-guards`

This repo's remote is `github.com/fu-infotrack/…`, which matches the installed `dev-guards` `repo_filter` (`infotrack`), and `main` is a `protected_branch`. So the plugin's own PreToolUse hook **denies a direct `git commit` on `main`**. Land changes via a feature branch, then fast-forward (no PR needed):

```bash
git checkout -b <branch>          # its OWN Bash tool call (see below)
git add … && git commit -m "…"    # separate call — branch is now unprotected
git checkout main && git merge --ff-only <branch> && git push origin main && git branch -d <branch>
```

`merge --ff-only` invokes no `git commit`, so it isn't blocked. **Keep `git checkout -b` and the commit in separate Bash tool calls**: the branch guard evaluates HEAD *before* the command runs, so a compound `checkout -b …; … commit` is judged while still on `main` and denied. (Bumping a plugin's `version` then `uninstall`+`install` is how you force the cache to pick up a changed bundled file, since `install` no-ops when the version is unchanged.)

## Runtime config — standardized on `fu-tools` layered config

Every plugin that needs runtime config (skills, commands, **and hooks**) reads the same `fu-tools` layered config rather than Claude Code's per-plugin `userConfig`. This keeps all repo/user settings in one place. Precedence (later wins):

```
CLI flags > nearest <ancestor>/.claude/.fu-tools.json > auto-detect (git remote, k8_settings app_name) > ~/.claude/fu-tools/config.json > defaults
```

Project file shape is `{ "<tool>": { ... } }`, keyed by tool name (e.g. `et-sweep`, `dev-guards`). **Resolution merges exactly two layers — the *nearest* `.claude/.fu-tools.json` (walk stops at the first hit) over `~/.claude/fu-tools/config.json`, shallow per-tool (project keys win). It does NOT cascade all ancestors.** A nearer project file therefore *shadows* a farther one: a value needed regardless of cwd (or that a nested repo's own `.fu-tools.json` would shadow) belongs in **user config**. Resolution is implemented twice — keep them behaviorally aligned:
- `scripts/fu-config.sh` (shell, walks ancestors of cwd). `fu-dev-guards` and the skill plugins each ship an identical copy. Scalars print one raw line; **arrays print one element per line** (consumers read with `while read`/`mapfile`); absent → nothing.
- `mergeConfig()` in `sweep-lib.mjs` (JS), used by `fu-et-sweep`.

Because the walk-up starts at the process cwd, a hook resolves config relative to **where the guarded command runs** (e.g. `git commit` runs inside the target repo). The `dev-guards` keys (`protected_branches`, `repo_filter`, `protected_dirs`, `protected_dir_exempt`) all live in user config so they apply everywhere. Hook scripts also accept env-var overrides (`PROTECTED_BRANCHES`, `REPO_FILTER`, `PROTECTED_DIRS`, `PROTECTED_DIR_EXEMPT`) that win over resolved config — used by the inline `Bash` tests.

Claude Code's plugin `userConfig` mechanism exists but is intentionally **not** used here — don't reintroduce it for a value that belongs in `fu-tools`.

## Code patterns

- **Pure logic split from I/O.** `fu-et-sweep/scripts/sweep-lib.mjs` is dependency-free, side-effect-free, and `node:test`-covered; `sweep.mjs` is the thin CLI wrapper the command shells out to. Date/time and network stay out of the testable core. Preserve this split when extending.
- **Hooks** live in `src/hooks/` as bash, referenced via `${CLAUDE_PLUGIN_ROOT}/src/hooks/...`. To block an action a PreToolUse hook emits a `hookSpecificOutput` JSON object with `permissionDecision: "deny"` and exits non-zero (2). `jq` is a hard dependency.
- **Token/context discipline** (et-sweep): the orchestrating command stays context-thin; expensive work (stack traces, source reads) is isolated inside subagents whose context never returns to the loop. A metadata-only triage gate drops noise before the investigator runs. See `plugins/fu-et-sweep/docs/DESIGN.md`.
- **PR-review orchestrator** (`fu-review-prs`): all irreversible/external steps (lock, state, GitHub post) are deterministic bash in the orchestrator; the per-PR review runs in a sub-agent whose context never returns. State (`last-reviewed-<pr>`: commit + tree SHA) is namespaced per repo and lives in `~/.claude/pr-review/`, outside the wiped plugin cache. The dedicated review clone is force-reset to a pristine `origin/main` at tick start **and** after each PR via `pr_review_reset_tree` (`fetch` → `checkout -f main` → `reset --hard origin/main` → `clean -fd` → prune all non-`main` local branches). Cross-Bash-call locks use a background `flock` holder process (a normal fd-flock would release when the bash call returns). See `plugins/fu-review-prs/docs/orchestrator-subagent-pr-review-bot.md`.
- **Vault DB-stage plugins** (`fu-pg-stage`, `fu-mssql-stage`) share one shape: `connect.sh` reads the Vault database-engine *config* (`<mount>/config/<db>`, default mount `database`) for the `connection_url` + `allowed_roles`, mints dynamic creds from a role, then assembles a connection (string / shell / `--export` env). The minted cred (a secret) is **cached** in a `0600` file under `~/.claude/fu-tools/cache/<tool>/`, keyed per `(vault, mount, db, role)`, reused until near lease expiry — `--fresh` bypasses, `--purge` wipes; a cache hit skips both Vault reads. `VAULT_ADDR` resolved from config must be **exported** so the `vault` child process sees it (else it falls back to `127.0.0.1:8200`). pg parses a `postgresql://` URI; mssql parses a percent-encoded ADO.NET string (`Server=…;Database=…`). The cache layer is duplicated per-plugin (same convention as `fu-config.sh`) — keep the two aligned.

## Tests

No test framework or install step — Node's built-in runner:

```bash
node --test plugins/fu-et-sweep/scripts/sweep-lib.test.mjs
```

`fu-ce-compound` ships a Python frontmatter validator (parser-safety checks, not schema validation):

```bash
python3 plugins/fu-ce-compound/skills/ce-compound/scripts/validate-frontmatter.py <doc-path>
```

## External dependencies (by plugin)

No package manager pulls these — they must be on PATH:
- `jq` — hard dependency of every hook and the config/DB scripts.
- `gh` (authenticated for the target repo) — `fu-et-sweep`, `fu-review-prs`.
- `vault` (authenticated, `VAULT_ADDR` set) — `fu-pg-stage`, `fu-mssql-stage`; plus `psql` (pg) / `sqlcmd` go-sqlcmd (mssql) to actually connect.
- `node` — `fu-et-sweep` and its `node --test` suite.
- `python3` — `fu-ce-compound` frontmatter validator.

## Plugins

| Plugin | Kind | Purpose |
|---|---|---|
| fu-et-sweep | command + agents + scripts + MCP | Datadog Error Tracking → de-duped GitHub issues with root-cause writeups |
| fu-review-prs | command + scripts | PR review orchestrator (self-contained: bundles `lib.sh` + `review-task.md`; runtime state stays in `~/.claude/pr-review`, namespaced per repo) |
| fu-inspecting-orders-api | skill | Orders API inspection (config-resolved host + token) |
| fu-pg-stage | skill | Postgres via HashiCorp Vault credentials |
| fu-mssql-stage | skill | SQL Server via HashiCorp Vault credentials (`sqlcmd`/go-sqlcmd; parses an ADO.NET connection_url) |
| fu-ce-compound | skill + agents | Document solved problems (EveryInc fork, MIT) |
| fu-dev-guards | hooks | Worktree path enforcement, protected-branch commit blocking, protected-directory edit + branch-switch blocking (forces worktrees), dotnet format pre-commit |

`fu-et-sweep` bundles its own MCP server in `.mcp.json` (`au-datadog-mcp`, HTTP, error-tracking toolset) and requires the `gh` CLI authenticated for the target repo. It must run in a live session for the MCP OAuth.
