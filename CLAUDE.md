# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **personal Claude Code plugin marketplace** — not an application. Each plugin under `plugins/` is a self-contained extension (skill, command, agents, hooks, scripts, and/or MCP server) that installs at user scope. There is no build step and no `package.json`; the "product" is the plugin directories plus the marketplace manifest.

## Repository layout

- `.claude-plugin/marketplace.json` — the marketplace registry. **Every plugin must be listed here** (`name`, `source`, `description`) or it cannot be installed. The marketplace `source` is a local `directory` pointing at this repo (see `~/.claude/plugins/known_marketplaces.json`).
- `plugins/<name>/.claude-plugin/plugin.json` — per-plugin manifest. The manifest's component keys (`commands`, `skills`, `hooks`, `userConfig`, etc.) declare what the plugin contributes.
- All plugins are prefixed `fu-` for provenance.

**When adding a plugin, update all three registries** or it's half-listed: `.claude-plugin/marketplace.json` (required to install), the **Plugins table in the root `README.md`**, and the **Plugins table at the bottom of this file**. Don't stop at `marketplace.json`.

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
- `scripts/fu-config.sh` (shell, walks ancestors of cwd). `fu-dev-guards` and the skill plugins each ship an identical copy. Scalars print one raw line; **arrays print one element per line** (consumers read with `while read`/`mapfile`); absent → nothing. A **dotted key is a nested path** (`fu-config.sh k8dash stage.url` → `.k8dash.stage.url`, via jq `getpath`); flat keys (no dot) behave as before, and the two-layer merge is a jq deep-merge so a project file can override one nested leaf.
- `mergeConfig()` in `sweep-lib.mjs` (JS), used by `fu-et-sweep`.

Because the walk-up starts at the process cwd, a hook resolves config relative to **where the guarded command runs** (e.g. `git commit` runs inside the target repo). The `dev-guards` keys (`protected_branches`, `repo_filter`, `protected_dirs`, `protected_dir_exempt`) all live in user config so they apply everywhere. Hook scripts also accept env-var overrides (`PROTECTED_BRANCHES`, `REPO_FILTER`, `PROTECTED_DIRS`, `PROTECTED_DIR_EXEMPT`) that win over resolved config — used by the inline `Bash` tests.

Claude Code's plugin `userConfig` mechanism exists but is intentionally **not** used here — don't reintroduce it for a value that belongs in `fu-tools`.

## Code patterns

- **Pure logic split from I/O.** `fu-et-sweep/scripts/sweep-lib.mjs` is dependency-free, side-effect-free, and `node:test`-covered; `sweep.mjs` is the thin CLI wrapper the command shells out to. Date/time and network stay out of the testable core. Preserve this split when extending.
- **Hooks** live in `src/hooks/` as bash, referenced via `${CLAUDE_PLUGIN_ROOT}/src/hooks/...`. To block an action a PreToolUse hook emits a `hookSpecificOutput` JSON object with `permissionDecision: "deny"` and exits non-zero (2). `jq` is a hard dependency.
- **Token/context discipline** (et-sweep): the orchestrating command stays context-thin; expensive work (stack traces, source reads) is isolated inside subagents whose context never returns to the loop. A metadata-only triage gate drops noise before the investigator runs. See `plugins/fu-et-sweep/docs/DESIGN.md`.
- **PR-review orchestrator** (`fu-review-prs`): all irreversible/external steps (lock, state, GitHub post) are deterministic bash in the orchestrator; the per-PR review runs in a sub-agent whose context never returns. State (`last-reviewed-<pr>`: commit + tree SHA) is namespaced per repo and lives in `~/.claude/pr-review/`, outside the wiped plugin cache. The dedicated review clone is force-reset to a pristine `origin/main` at tick start **and** after each PR via `pr_review_reset_tree` (`fetch` → `checkout -f main` → `reset --hard origin/main` → `clean -fd` → prune all non-`main` local branches). Cross-Bash-call locks use a background `flock` holder process (a normal fd-flock would release when the bash call returns). The pre-flight→post handoff is **disk-based, not context-carried**, so a mid-tick context compaction loses nothing: pre-flight persists `pending-<pr>` (commit+tree) and the sub-agent writes its decision to a `decision-<pr>.txt` sidecar **and** a `<!-- DECISION: X -->` body header; `pr_review_finish <pr>` takes only the PR and recovers commit/tree/decision/body from disk (decision: sidecar → header → `COMMENT`). See `plugins/fu-review-prs/docs/orchestrator-subagent-pr-review-bot.md`.
- **Vault DB-stage plugin** (`fu-pg-stage`): `connect.sh` reads the Vault database-engine *config* (`<mount>/config/<db>`, default mount `database`) for the `connection_url` + `allowed_roles`, mints dynamic creds from a role, then assembles a connection (string / shell / `--export` env). The minted cred (a secret) is **cached** in a `0600` file under `~/.claude/fu-tools/cache/<tool>/`, keyed per `(vault, mount, db, role)`, reused until near lease expiry — `--fresh` bypasses, `--purge` wipes; a cache hit skips both Vault reads. `VAULT_ADDR` resolved from config must be **exported** so the `vault` child process sees it (else it falls back to `127.0.0.1:8200`). pg parses a `postgresql://` URI. (`fu-mssql-stage` used to share this shape but was cut over to Windows auth — see below.)
- **`fu-mssql-stage` — Windows (integrated) auth, no Vault** (since v0.3.0): `connect.sh` detects the platform and connects with `sqlcmd -E -C` (native Windows) or the **Windows-host `sqlcmd.exe -E -C`** under WSL via PATH interop (the Linux `go-sqlcmd` has no NTLM, and these hosts have no Kerberos SPN, so only the Windows client authenticates); plain Linux/macOS errors out. No secret is handled — the host is the only stateful value. **Hosts are named** (v0.4.0), k8dash-style: `mssql-stage.<name>.host` + `mssql-stage.defaultHost`, resolved via `fu-config.sh`'s dotted-path lookup. `-S` takes a **name or a literal host** (named lookup `<sel>.host`, else literal); no `-S` → `defaultHost` (else legacy `winHost`, else prompt→persist as `default`). `--save-as <name>` (+ `--default`) registers a host; `persist_host()`/`set_default_host()` merge into user config via jq (other tools' keys preserved). Same three output modes as pg (default ADO.NET `Integrated Security=true` string / `--sqlcmd` exec / `--export`). `scripts/fu-config.sh` is unchanged.
- **Proxy-replay access** (`fu-k8dash`): no kubectl/kubeconfig — `scripts/k8dash` replays what the k8dash browser does, attaching the user's OIDC bearer token to standard apiserver REST calls through the dashboard's pass-through proxy. The reach is exactly the user's RBAC (no escalation). **GET-only by construction**: one `curl -X GET` primitive (`k8get`), zero mutating subcommands — verifiable by grep. `raw <path>` is the primary contract; named subcommands are sugar. Each summarising subcommand fetches into a var **before** printing its header so a no-token/401/403 dies cleanly (no header-then-error). **Multi-cluster**: a leading `-c <cluster>` picks the cluster (nested config `k8dash.<cluster>.url`, resolved via `fu-config.sh`'s dotted-path lookup; omitted → `defaultCluster`; prod is never default and prints a ⚠ banner — no mutable current-context, so you can't hit prod by omission). Each cluster's token lives at `~/.claude/fu-tools/k8dash/clusters/<cluster>/token` (0600), captured by `login` (headed-browser OIDC / clipboard / stdin) — never echoed, never a repo/cache file. See `plugins/fu-k8dash/docs/k8dash-proxy-access.md`.

## Tests

No test framework or install step — Node's built-in runner:

```bash
node --test plugins/fu-et-sweep/scripts/sweep-lib.test.mjs
```

`fu-ce-compound` ships a Python frontmatter validator (parser-safety checks, not schema validation):

```bash
python3 plugins/fu-ce-compound/skills/ce-compound/scripts/validate-frontmatter.py <doc-path>
```

`fu-dev-guards` ships a plain-bash suite for the shared git-guard helper (segment + head-match) and the hooks that source it — unit cases plus env-seam-driven end-to-end denials:

```bash
bash plugins/fu-dev-guards/test/git-guard.test.sh
```

## External dependencies (by plugin)

No package manager pulls these — they must be on PATH:
- `jq` — hard dependency of every hook and the config/DB scripts.
- `gh` (authenticated for the target repo) — `fu-et-sweep`, `fu-review-prs`.
- `vault` (authenticated, `VAULT_ADDR` set) — `fu-pg-stage`; plus `psql` to actually connect.
- `sqlcmd` — `fu-mssql-stage`: on Windows the ODBC `sqlcmd` (v17/18) or `go-sqlcmd`; under WSL the **Windows-host `sqlcmd.exe`** on PATH (interop). No `vault`. `jq` only to persist the host.
- `node` — `fu-et-sweep` and its `node --test` suite.
- `python3` — `fu-ce-compound` frontmatter validator.
- `curl` — `fu-k8dash` (the only hard dep; `jq` optional, used for formatting).
- `pup` — `fu-datadog-pup` (a skill + a bundled `scripts/install-pup.sh` that installs/updates the binary) **and `fu-et-sweep`** (its sole Datadog access path since v0.2.0). The Datadog API CLI; authenticated via `pup auth login` or `DD_API_KEY`/`DD_APP_KEY`/`DD_SITE`.
- `wsl.exe`, PowerShell 7+, `winget` — `fu-wsl-setup` (Windows-host only; drives a Debian/Ubuntu WSL instance).

## Plugins

| Plugin | Kind | Purpose |
|---|---|---|
| fu-et-sweep | command + agents + scripts | Datadog Error Tracking → de-duped GitHub issues with root-cause writeups (Datadog via the `pup` CLI) |
| fu-log-sweep | command + agents + scripts | Datadog error-level Logs → de-duped GitHub issues with root-cause writeups; sibling to fu-et-sweep, dedups on a self-computed error signature (`type\|service\|top-app-frame` sha1) instead of an ET `issue_id` |
| fu-review-prs | command + scripts | PR review orchestrator (self-contained: bundles `lib.sh` + `review-task.md`; runtime state stays in `~/.claude/pr-review`, namespaced per repo) |
| fu-inspecting-orders-api | skill | Orders API inspection (config-resolved host + token) |
| fu-pg-stage | skill | Postgres via HashiCorp Vault credentials |
| fu-mssql-stage | skill | SQL Server via Windows (integrated) auth — `sqlcmd -E` native, or the Windows-host `sqlcmd.exe` under WSL (PATH interop); named hosts + default (`-S` name or literal), no Vault |
| fu-k8dash | skill | Read-only K8s inspection across clusters (stage/prod, pick with `-c`) via the k8dash dashboard's pass-through API proxy (GET-only, RBAC-bounded; user's OIDC bearer token) |
| fu-datadog-pup | skill | Query Datadog from the terminal with the `pup` CLI — logs/traces search, Error Tracking triage, auth/meta ops (pure-docs skill; no scripts/config) |
| fu-ce-compound | skill + agents | Document solved problems (EveryInc fork, MIT) |
| fu-dev-guards | hooks | Worktree path enforcement, protected-branch commit blocking, protected-directory edit + branch-switch blocking (forces worktrees), dotnet format pre-commit |
| fu-wsl-setup | skill | Provision a WSL work environment for Claude Code from Windows PowerShell 7+ — WSL version check, pick/create a Debian instance, then drive the full tool install sequence (non-interactive work automated, privileged/interactive steps handed to the user) |

`fu-et-sweep` reads Datadog Error Tracking through the **`pup` CLI** (run via Bash; see `fu-datadog-pup`) — **no bundled MCP server** as of v0.2.0 — plus the `gh` CLI authenticated for the target repo. Run it in a live session so `pup auth login` / `gh` auth is available (a `401` needs an interactive re-login). Key design wrinkle: `pup`'s ET `issues search` is a **thin projection (id + total_count only)**, so the orchestrator count-prunes then **gh-dedups first** to bound the set to ≤10, and only then hydrates each survivor via `pup error-tracking issues get` for the rich fields. **Regression is derived from a closed GitHub match** (GH is the sole regression authority — `pup` has no Datadog regression flag). The investigator pulls a sample stack via `pup traces/logs search '@issue.id:<id>'` (replacing the old `analyze_*` MCP tool). The pure-logic `sweep-lib.mjs` is shape-agnostic and was untouched by the cutover.
