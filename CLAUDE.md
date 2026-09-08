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

For a quick single-file test, you can `cp` the changed file straight into the cache path, but the full reinstall is the correct path. When adding a new plugin, edit `marketplace.json` first, then `marketplace update` before `install`.

Plugin **hooks load at session start**, but an `uninstall`+`install` cycle was observed to swap them in **mid-session** (a hook fix installed this way started firing immediately, without a restart). So don't assume the running session still has the old behaviour — verify by exercising the hook rather than reasoning from "hooks need a restart".

## Always work in a worktree here — this repo is guarded by its own `fu-dev-guards`

This repo's path is a `protected_dir`, its remote `github.com/fu-infotrack/…` matches `repo_filter` (`infotrack`), and `main` is a `protected_branch`. In the **main checkout** the installed hooks therefore deny:

| Action | In main checkout | In a worktree |
|---|---|---|
| `Write` / `Edit` any file | **denied** (`guard-protected-dirs`) | allowed (`/.claude/` is exempt) |
| `git checkout` / `switch` / `gh pr checkout` | **denied** (`guard-protected-checkout`) | allowed |
| `git commit` on `main` | **denied** (`guard-protected-branch`) | allowed (branch ≠ `main`) |

So editing in place is impossible, and **`git checkout -b` from the main checkout is itself denied** — do not start there. Multiple background sessions may also be running against this repo at once, and they would otherwise share one index and one HEAD (session A's `git add -A && commit` swallows session B's half-finished edits). **Begin every change by calling `EnterWorktree` (name: `<branch-name>`)**, then branch/commit/push inside it:

```bash
# inside the worktree — Write/Edit and git are unguarded here
git add … && git commit -m "…"
git push -u origin HEAD:<branch>
gh pr create --base main …          # land via PR, squash-merged
```

Land via **PR, squash-merged** — never push `main` directly (`gh pr merge <n> --squash --delete-branch`). Then in the main checkout `git pull --ff-only origin main`, and `ExitWorktree` (`remove` once the branch is merged — its pre-squash commit is redundant).

A **SessionStart** hook (`notify-worktree-sessionstart.sh`) states this up front whenever a session opens inside a protected root, so it isn't rediscovered via a denial. It is advisory — the PreToolUse guards are the enforcement — and stays silent outside protected dirs and inside worktrees.

Because worktrees share the repo's refs, a branch can only be checked out in one at a time (git refuses otherwise) — **name each session's worktree after its task** so concurrent sessions never collide.

**Known gap:** the Write/Edit guard matches only those tools, so a Bash write (`cat > file`, `tee`, `sed -i`) into a protected dir is **not** blocked — measured, not theoretical. Don't route around the guard that way.

**Worktrees do not isolate `~/.claude/`.** The plugin cache, `fu-tools` config, and `pr-review` state are shared, and `claude plugin install` rewrites the cache **for every session**. Serialize install/marketplace steps to one session.

To force the cache to pick up a changed bundled file, bump the plugin's `version` then `uninstall`+`install` — plain `install` no-ops when the version is unchanged (it reports "already installed" and silently keeps the old files).

## Runtime config — standardized on `fu-tools` layered config

Every plugin that needs runtime config (skills, commands, **and hooks**) reads the same `fu-tools` layered config rather than Claude Code's per-plugin `userConfig`. This keeps all repo/user settings in one place. Precedence (later wins):

```
CLI flags > nearest <ancestor>/.claude/.fu-tools.json > auto-detect (git remote, k8_settings app_name) > ~/.claude/fu-tools/config.json > defaults
```

**That chain is the union of two implementations, and the shell one is a strict subset — the auto-detect layer exists ONLY in JS.** `mergeConfig()` takes an `autoObj`; `fu-config.sh` has no equivalent and merges exactly two layers, so for every shell consumer (`fu-skills`, `fu-dev-guards`, `fu-review-prs`) an unset key is simply **absent** — nothing is inferred from the git remote or `k8_settings`. Read the chain above as aspirational for those, not as behaviour. Measured 2026-08-13, after the gap was mistaken for a bug in the `fu-pg` skill (then the `fu-pg-stage` plugin): `app_name` is the wrong key for a Vault db-config anyway (it is per-**deployment** — `infotrackcredit-worker`, `asicapi-consumer` — while a db-config is per-**database**; 1 of 74 `app_name` values on this machine matched any of the 107 `database/config` keys). The **repo name** is the closer key — it matched both repos that have a Postgres config, one exactly (`EntityPlatform`) and one only case-insensitively (`InfoTrackCredit` → `infotrackcredit`) — so any future auto-detect should resolve a candidate against `vault list database/config` rather than trust a derived string.

Project file shape is `{ "<tool>": { ... } }`, keyed by tool name (e.g. `et-sweep`, `dev-guards`). **Resolution merges exactly two layers — the *nearest* `.claude/.fu-tools.json` (walk stops at the first hit) over `~/.claude/fu-tools/config.json`, shallow per-tool (project keys win). It does NOT cascade all ancestors.** A nearer project file therefore *shadows* a farther one: a value needed regardless of cwd (or that a nested repo's own `.fu-tools.json` would shadow) belongs in **user config**. Resolution is implemented twice — keep them behaviorally aligned:
- `scripts/fu-config.sh` (shell, walks ancestors of cwd). `fu-dev-guards`, `fu-review-prs`, and `fu-skills` each ship an identical copy (`fu-skills` holds the single copy all its skills share). Scalars print one raw line; **arrays print one element per line** (consumers read with `while read`/`mapfile`); absent → nothing. A **dotted key is a nested path** (`fu-config.sh k8dash stage.url` → `.k8dash.stage.url`, via jq `getpath`); flat keys (no dot) behave as before, and the two-layer merge is a jq deep-merge so a project file can override one nested leaf.
- `mergeConfig()` in `sweep-lib.mjs` (JS), used by `fu-et-sweep`.

Because the walk-up starts at the process cwd, a hook resolves config relative to **where the guarded command runs** (e.g. `git commit` runs inside the target repo). The `dev-guards` keys (`protected_branches`, `repo_filter`, `protected_dirs`, `protected_dir_exempt`) all live in user config so they apply everywhere. Hook scripts also accept env-var overrides (`PROTECTED_BRANCHES`, `REPO_FILTER`, `PROTECTED_DIRS`, `PROTECTED_DIR_EXEMPT`) that win over resolved config — used by the inline `Bash` tests.

Claude Code's plugin `userConfig` mechanism exists but is intentionally **not** used here — don't reintroduce it for a value that belongs in `fu-tools`.

## Code patterns

- **Pure logic split from I/O.** `fu-et-sweep/scripts/sweep-lib.mjs` is dependency-free, side-effect-free, and `node:test`-covered; `sweep.mjs` is the thin CLI wrapper the command shells out to. Date/time and network stay out of the testable core. Preserve this split when extending.
- **Hooks** live in `src/hooks/` as bash, referenced via `${CLAUDE_PLUGIN_ROOT}/src/hooks/...`. To block an action a PreToolUse hook emits a `hookSpecificOutput` JSON object with `permissionDecision: "deny"` and exits non-zero (2). `jq` is a hard dependency.

## Per-plugin rules live with the plugin

Everything above is true whichever plugin you are in. Everything *specific* to one plugin —
its design rationale, its measured constraints, its test suites — lives in that plugin's own
`CLAUDE.md`. **Read it before changing that plugin.**

These nested files load when Claude works with files in the subtree, but that is not a
guarantee: a session that only ever reads a file through `cat` in a Bash call may never pull
one in. If you are about to change a plugin and have not seen its `CLAUDE.md` in context,
open it explicitly.

| Plugin | Read first | Why it matters |
|---|---|---|
| fu-copilot | `plugins/fu-copilot/CLAUDE.md` | Four constraints measured against the real Copilot CLI (it cannot read `~/.claude`; the brief must be inlined prompt text; never foreground; a self-report is not a completion signal), plus the AI-credit cap and flag policy |
| fu-review-prs | `plugins/fu-review-prs/CLAUDE.md` | Which steps must stay deterministic bash, the disk-based (compaction-immune) handoff, approve-is-opt-in, the blocker-count rule, house rules |
| fu-skills | `plugins/fu-skills/CLAUDE.md` | Per-skill designs: `fu-pg` (Vault, LDAP, the `--export` failure contract), `fu-mssql` (Windows auth, named hosts), `fu-k8` (GET-only proxy replay) |
| fu-dev-guards | `plugins/fu-dev-guards/CLAUDE.md` | The command-matching rule (`cmd_invokes`, "data is not a command"), advisory-vs-enforcement, and the session-stamp marker wire format |
| fu-et-sweep | `plugins/fu-et-sweep/CLAUDE.md` | Token discipline, and the `pup` ET thin-projection wrinkle that drives the prune→dedup→hydrate order |
| fu-log-sweep | `plugins/fu-log-sweep/CLAUDE.md` | The self-computed error signature it dedups on — a wire format |
| fu-statusline | `plugins/fu-statusline/CLAUDE.md` | Why the renderer cannot run from the plugin cache, and the `fu-statusline` marker token you must not remove |

When you add a plugin, give it a `CLAUDE.md` and a row here — alongside the three registries
listed under **Repository layout**.

## Tests

No test framework and no install step: Node's built-in runner for JS, plain bash for
everything else. Every suite is hermetic — throwaway `$HOME`, stubs on PATH, pinned clocks —
so nothing installs, nothing reaches a real service, and no real external run starts. Each
plugin's `CLAUDE.md` says what its suites actually assert; the whole set is:

```bash
node --test plugins/fu-et-sweep/scripts/sweep-lib.test.mjs
bash plugins/fu-copilot/test/dispatch.test.sh
bash plugins/fu-copilot/test/verify.test.sh
bash plugins/fu-dev-guards/test/git-guard.test.sh
bash plugins/fu-dev-guards/test/stamp-session.test.sh
bash plugins/fu-review-prs/test/auto-approve.test.sh
bash plugins/fu-review-prs/test/notify.test.sh
bash plugins/fu-skills/test/export-guard.test.sh
bash plugins/fu-statusline/test/install.test.sh
bash plugins/fu-statusline/test/statusline.test.sh
```

Plus a validator, not a suite — the `fu-ce` skill's frontmatter parser-safety check:

```bash
python3 plugins/fu-skills/skills/fu-ce/scripts/validate-frontmatter.py <doc-path>
```

Two harness gotchas cost time when writing the bash suites, both worth not rediscovering:
`env "PATH=$empty" bash …` fails because **`env` resolves `bash` through the new PATH**
(use `"$BASH"`), and a password containing a single quote cannot be interpolated into
`bash -c "eval \"$OUT\""` — source the export lines from a file instead.

## External dependencies (by plugin)

No package manager pulls these — they must be on PATH:
- `jq` — hard dependency of every hook, the config/DB scripts, and the `fu-statusline` renderer (which also shells out to `git`, and to nothing else).
- `gh` (authenticated for the target repo) — `fu-et-sweep`, `fu-review-prs`.
- `vault` (authenticated, `VAULT_ADDR` set) — the `fu-pg` skill; plus `psql` to actually connect.
- `sqlcmd` — the `fu-mssql` skill: on Windows the ODBC `sqlcmd` (v17/18) or `go-sqlcmd`; under WSL the **Windows-host `sqlcmd.exe`** on PATH (interop). No `vault`. `jq` only to persist the host.
- `node` — `fu-et-sweep` and its `node --test` suite.
- `python3` — the `fu-ce` skill's frontmatter validator.
- `curl` — the `fu-k8` skill (the only hard dep; `jq` optional, used for formatting); `fu-review-prs` only when a notification channel is configured.
- `pup` — the `fu-pup` skill (plus the bundled `scripts/install-pup.sh` that installs/updates the binary) **and `fu-et-sweep`** (its sole Datadog access path since v0.2.0). The Datadog API CLI; authenticated via `pup auth login` or `DD_API_KEY`/`DD_APP_KEY`/`DD_SITE`.
- `copilot` (GitHub Copilot CLI, authenticated) — `fu-copilot` only. Its test suites stub it on PATH, so they need nothing installed.
- `wsl.exe`, PowerShell 7+, `winget` — the `fu-wsl` skill (Windows-host only; drives a Debian/Ubuntu WSL instance).


## Plugins

| Plugin | Kind | Purpose |
|---|---|---|
| fu-et-sweep | command + agents + scripts | Datadog Error Tracking → de-duped GitHub issues with root-cause writeups (Datadog via the `pup` CLI) |
| fu-log-sweep | command + agents + scripts | Datadog error-level Logs → de-duped GitHub issues with root-cause writeups; sibling to fu-et-sweep, dedups on a self-computed error signature (`type\|service\|top-app-frame` sha1) instead of an ET `issue_id` |
| fu-review-prs | command + scripts | PR review orchestrator (self-contained: bundles `lib.sh` + `review-task.md`; runtime state stays in `~/.claude/pr-review`, namespaced per repo). Comment-only by default — `--auto-approve` to approve clean PRs |
| fu-skills | skills + agents + scripts | **All scenario skills in one plugin.** `/fu-pg` (Postgres via HashiCorp Vault credentials) and `/fu-pup` (Datadog via the `pup` CLI) stay model-invocable — they're daily drivers and auto-trigger. The rest are `disable-model-invocation: true` (zero context until explicitly invoked): `/fu-mssql` (SQL Server via Windows integrated auth — `sqlcmd -E` native, or the Windows-host `sqlcmd.exe` under WSL; named hosts + default), `/fu-k8` (read-only K8s across clusters via the k8dash pass-through proxy, GET-only, user's OIDC token), `/fu-order` (Orders API inspection), `/fu-wsl` (provision a WSL work environment from Windows PowerShell 7+), `/fu-ce` (document solved problems; EveryInc fork, MIT — ships the ce-* review agents). `/ask-fu` (also hidden) is the catalogue/router for when the name escapes you. **fu-tools config keys are unchanged** (`pg-stage`, `mssql-stage`, `k8dash`, `inspecting-orders-api`) — the scripts kept their tool names, so no config migration |
| fu-copilot | skill + agent + scripts | Delegate a coding task to GitHub Copilot CLI and verify the outcome from git. `dispatch.sh` stages the brief in `/tmp`, inlines it into `-p`, launches detached and confirms it reached the process; `verify.sh` waits on the PID and checks HEAD moved / empty commits / losslessness / log denials |
| fu-dev-guards | hooks | Worktree path enforcement, protected-branch commit blocking, protected-directory edit + branch-switch blocking (forces worktrees), a SessionStart notice when a session opens in a protected checkout, a SessionStart session-id stamp for PR bodies, dotnet format pre-commit |
| fu-statusline | commands + scripts | Bash + jq Claude Code status line renderer — drop-in for `npx ccstatusline` (12.3 ms/11 MB vs 605 ms/103 MB per render). `/statusline-config install` copies the renderer to `~/.claude/statusline/` and patches `settings.json`, because `statusLine` is **not** a plugin capability |
