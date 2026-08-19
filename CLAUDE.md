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

**That chain is the union of two implementations, and the shell one is a strict subset — the auto-detect layer exists ONLY in JS.** `mergeConfig()` takes an `autoObj`; `fu-config.sh` has no equivalent and merges exactly two layers, so for every shell consumer (`fu-pg-stage`, `fu-mssql-stage`, `fu-k8dash`, `fu-dev-guards`, `fu-review-prs`) an unset key is simply **absent** — nothing is inferred from the git remote or `k8_settings`. Read the chain above as aspirational for those, not as behaviour. Measured 2026-08-13, after the gap was mistaken for a bug in `fu-pg-stage`: `app_name` is the wrong key for a Vault db-config anyway (it is per-**deployment** — `infotrackcredit-worker`, `asicapi-consumer` — while a db-config is per-**database**; 1 of 74 `app_name` values on this machine matched any of the 107 `database/config` keys). The **repo name** is the closer key — it matched both repos that have a Postgres config, one exactly (`EntityPlatform`) and one only case-insensitively (`InfoTrackCredit` → `infotrackcredit`) — so any future auto-detect should resolve a candidate against `vault list database/config` rather than trust a derived string.

Project file shape is `{ "<tool>": { ... } }`, keyed by tool name (e.g. `et-sweep`, `dev-guards`). **Resolution merges exactly two layers — the *nearest* `.claude/.fu-tools.json` (walk stops at the first hit) over `~/.claude/fu-tools/config.json`, shallow per-tool (project keys win). It does NOT cascade all ancestors.** A nearer project file therefore *shadows* a farther one: a value needed regardless of cwd (or that a nested repo's own `.fu-tools.json` would shadow) belongs in **user config**. Resolution is implemented twice — keep them behaviorally aligned:
- `scripts/fu-config.sh` (shell, walks ancestors of cwd). `fu-dev-guards`, `fu-review-prs`, and the skill plugins each ship an identical copy. Scalars print one raw line; **arrays print one element per line** (consumers read with `while read`/`mapfile`); absent → nothing. A **dotted key is a nested path** (`fu-config.sh k8dash stage.url` → `.k8dash.stage.url`, via jq `getpath`); flat keys (no dot) behave as before, and the two-layer merge is a jq deep-merge so a project file can override one nested leaf.
- `mergeConfig()` in `sweep-lib.mjs` (JS), used by `fu-et-sweep`.

Because the walk-up starts at the process cwd, a hook resolves config relative to **where the guarded command runs** (e.g. `git commit` runs inside the target repo). The `dev-guards` keys (`protected_branches`, `repo_filter`, `protected_dirs`, `protected_dir_exempt`) all live in user config so they apply everywhere. Hook scripts also accept env-var overrides (`PROTECTED_BRANCHES`, `REPO_FILTER`, `PROTECTED_DIRS`, `PROTECTED_DIR_EXEMPT`) that win over resolved config — used by the inline `Bash` tests.

Claude Code's plugin `userConfig` mechanism exists but is intentionally **not** used here — don't reintroduce it for a value that belongs in `fu-tools`.

## Code patterns

- **Pure logic split from I/O.** `fu-et-sweep/scripts/sweep-lib.mjs` is dependency-free, side-effect-free, and `node:test`-covered; `sweep.mjs` is the thin CLI wrapper the command shells out to. Date/time and network stay out of the testable core. Preserve this split when extending.
- **Hooks** live in `src/hooks/` as bash, referenced via `${CLAUDE_PLUGIN_ROOT}/src/hooks/...`. To block an action a PreToolUse hook emits a `hookSpecificOutput` JSON object with `permissionDecision: "deny"` and exits non-zero (2). `jq` is a hard dependency.
- **Matching a command in a Bash hook** — never `grep` the raw command string. `^\s*git\s+commit` only sees the FIRST token, so `git fetch && git commit` bypasses it; an unanchored `\bgit\s+commit\b` instead false-blocks the verb in quoted prose. All four git guards share `fu-dev-guards/src/hooks/lib/git-guard.sh`: `cmd_invokes "$cmd" 'git commit'` segments on **unquoted** boundaries, peels leading assignments/wrappers/`\`, and head-matches. The governing rule is **data is not a command** — quoted strings and heredoc bodies are inert, while `$( )`, backticks, and `sh -c` payloads are commands wherever they appear. Extend the tests in `test/git-guard.test.sh` when touching it.
- **Advisory hooks vs enforcement** — `stamp-session-sessionstart.sh` (v0.4.0) joins `notify-worktree-sessionstart.sh` as the plugin's **second advisory hook**: the PreToolUse guards are the enforcement, these two only inform. It hands the session its own `session_id` via `additionalContext` and asks for `<!-- claude-session: <uuid> -->` at the bottom of every PR body. Two reasons not to add a deny backstop, both measured against the raw-command rule above: finding the marker means grepping the **raw** command string (the marker is *data*, so `cmd_invokes` deliberately discards it along with the heredoc body it usually lives in), and a deny would fire in every drive-by repo that never heard of the convention. The cost of not enforcing is asymmetric and worth stating honestly — a missed stamp loses the trace **outright**, because the id you would search by is the thing that went missing; recovery means content-grepping every transcript under `~/.claude/projects`. Registered with **no matcher** so it re-fires on `clear`/`compact`/`resume` — load-bearing, since a compaction would otherwise leave every later PR in the session unstamped. Ungated (every session, every directory), unlike its siblings: the id is a v4 UUID, inert without this machine's `~/.claude`. **The marker text is a wire format** — older PRs are found by grepping it, so changing it orphans them, which is why the hook refuses any id outside `[A-Za-z0-9._-]` rather than emit a marker split across lines or closed early by a stray `>`. Placement is the **bottom of the body, below** the `🤖 Generated with Claude Code` footer — deliberately *not* "the last line", since the harness separately requires that footer to end the body and two rules claiming last place get resolved at random. Bottom also lands the marker in trailer position **if** the repo is configured to prefill squash commit bodies from the PR description; GitHub's default prefills from commit messages instead, so don't expect `git log --grep 'claude-session'` to find it.
- **Token/context discipline** (et-sweep): the orchestrating command stays context-thin; expensive work (stack traces, source reads) is isolated inside subagents whose context never returns to the loop. A metadata-only triage gate drops noise before the investigator runs. See `plugins/fu-et-sweep/docs/DESIGN.md`.
- **PR-review orchestrator** (`fu-review-prs`): all irreversible/external steps (lock, state, GitHub post) are deterministic bash in the orchestrator; the per-PR review runs in a sub-agent whose context never returns. State (`last-reviewed-<pr>`: commit + tree SHA) is namespaced per repo and lives in `~/.claude/pr-review/`, outside the wiped plugin cache. The dedicated review clone is force-reset to a pristine `origin/main` at tick start **and** after each PR via `pr_review_reset_tree` (`fetch` → `checkout -f main` → `reset --hard origin/main` → `clean -fd` → prune all non-`main` local branches). Cross-Bash-call locks use a background `flock` holder process (a normal fd-flock would release when the bash call returns). The pre-flight→post handoff is **disk-based, not context-carried**, so a mid-tick context compaction loses nothing: pre-flight persists `pending-<pr>` (commit+tree) and the sub-agent writes its decision to a `decision-<pr>.txt` sidecar **and** a `<!-- DECISION: X -->` body header; `pr_review_finish <pr>` takes only the PR and recovers commit/tree/decision/body from disk (decision: sidecar → header → `COMMENT`). **Approving is opt-in** (since v0.2.0): the sub-agent's `APPROVE` means only "zero BLOCKERs", and `pr_review_finish` downgrades it to `COMMENT` unless the tick was started as `/review-prs --auto-approve` — `pr_review_init $ARGUMENTS` records that mode in `state/<slug>/auto-approve` (on disk, for the same compaction-immunity reason) and cleanup clears it. Findings post either way; only the review event changes. **Notifications** (v0.3.0) hang off the same point: `pr_review_notify` fires on a posted review (decision + BLOCKER count), a failed POST, and an empty body — the failure cases being the silent misses, since the bot reviews as *your* GitHub account and GitHub never notifies you of your own actions. Channels are opt-in via `fu-tools` (`review-prs.notify`: `teams`, `bell`; plus `review-prs.teams_webhook`), so no config = silent. The Teams webhook URL is a bearer credential — user config only, and **never logged** (asserted by a test); Power Automate's trigger must be set to *"Anyone"* or an unauthenticated `curl` gets `401 DirectApiAuthorizationRequired`. **Review effort is always explicit, never bare** (since v0.3.3): `review-task.md` invokes `/code-review` with a level the sub-agent picks itself — `low` for a small/simple scope, `medium` otherwise — because a bare `/code-review` reuses whatever level was last typed in the invoking context, undefined for a fresh sub-agent. Capped at `medium`; `high`/`xhigh`/`max` are out of scope for an unattended tick. See `plugins/fu-review-prs/docs/orchestrator-subagent-pr-review-bot.md` for the rationale, and `plugins/fu-review-prs/docs/pr-review-bot-spec.md` for the same design as an OS-/language-/forge-agnostic conformance spec (numbered requirements + failure modes, ports, a 32-case test suite, and this bash implementation's known deviations — `flock` holder instead of a TTL lease record, mtime instead of a stored `reviewed_at`, non-atomic state writes).
- **Vault DB-stage plugin** (`fu-pg-stage`): `connect.sh` reads the Vault database-engine *config* (`<mount>/config/<db>`, default mount `database`) for the `connection_url` + `allowed_roles`, mints dynamic creds from a role, then assembles a connection (string / shell / `--export` env). The minted cred (a secret) is **cached** in a `0600` file under `~/.claude/fu-tools/cache/<tool>/`, keyed per `(vault, mount, db, role)`, reused until near lease expiry — `--fresh` bypasses, `--purge` wipes; a cache hit skips both Vault reads. `VAULT_ADDR` resolved from config must be **exported** so the `vault` child process sees it (else it falls back to `127.0.0.1:8200`). pg parses a `postgresql://` URI. (`fu-mssql-stage` used to share this shape but was cut over to Windows auth — see below.) **`--export` fails loud** (v0.3.0): every failure writes to stderr and nothing to stdout, so the documented `eval "$(connect.sh --export)"` used to eval an *empty string* — succeeding with `$? = 0` and no `PG*` set, after which psql fell back to the **local unix socket** and the error read as "stage is down". An EXIT trap now emits `echo …>&2` + `false` on any non-zero exit that printed no assignment, so eval propagates the failure. It emits **`false`, never `exit`** — the output runs in the caller's interactive shell, where `exit` would close their terminal — and deliberately does **not** unset pre-existing `PG*`, which may belong to another database. Arg parsing and the `vault`/`jq` dependency checks were moved *above* the trap install so every failure path is covered (`mode` must be known before the trap can decide). The other two output modes **cannot** self-guard, since their stdout is a URI/exec rather than shell code — the doc prescribes `conn=$(connect.sh) || return` there. Locked down by `test/export-guard.test.sh`, which also asserts that gap so it stays a decision rather than a surprise. Separately, **the login method is LDAP** (`vault login -method=ldap username=<user>`) — a password login, no browser and no IdP round-trip. Getting there cost a wrong turn worth recording. `sys/internal/ui/mounts` is the natural way to ask what a Vault accepts, but it lists only mounts whose `listing_visibility` is `unauth` (what the UI's login dropdown shows) and **hidden is the default** — so a live mount can be absent from it. Stage returns only `oidc/` there while `ldap/` works fine, and an earlier revision of these docs read that listing as proof LDAP had been retired, then built an entire OIDC apparatus (browser-capture script, `AADSTS50011`/redirect-URI analysis, `callbackport` overrides) on top of the mistake — all of it since deleted. **Absence from that listing is not absence.** To prove a mount exists, probe **its own login path** (`auth/<m>/login/<user>`) with an **empty body**: Vault's ACL check precedes request-body validation, so an absent mount answers `403` whatever you send while a live one grades the payload — `403` means gone, anything else (stage answers `500 "password cannot be of zero length…"`, an error only the LDAP backend emits) means it's there. Probe with a **throwaway username** — Vault's user-lockout counter keys on the *account*, so anything the probe is charged for lands on a name nobody owns; omitting the password helps but is not a guarantee (the `500` says it reached the backend), and probing your own name with a guessed password is the thing to never do. The mount's *own* path matters just as much, since the ACL keys on the full path: measured 2026-08-19 against a mount **known to exist**, `auth/ldap/login/probeuser` → `500` (alive) while `auth/ldap/oidc/auth_url` → `403` (reads as gone). Same live mount, opposite verdicts — which is almost certainly how the original wrong call was made. Whether `ldap/` was truly removed and later restored, or was never gone and only mis-probed, **cannot be settled** (`sys/auth`/`sys/mounts` are 403 for a developer token). The durable rule: re-probe the login path when it matters; never trust a dated "that method is gone". One more reporting trap — an OIDC/federated token's `.data.policies` is always just `["default"]` and the real grant lands in `.data.identity_policies`, so printing only the former makes a fully privileged token look unauthorized.
- **`fu-mssql-stage` — Windows (integrated) auth, no Vault** (since v0.3.0): `connect.sh` detects the platform and connects with `sqlcmd -E -C` (native Windows) or the **Windows-host `sqlcmd.exe -E -C`** under WSL via PATH interop (the Linux `go-sqlcmd` has no NTLM, and these hosts have no Kerberos SPN, so only the Windows client authenticates); plain Linux/macOS errors out. No secret is handled — the host is the only stateful value. **Hosts are named** (v0.4.0), k8dash-style: `mssql-stage.<name>.host` + `mssql-stage.defaultHost`, resolved via `fu-config.sh`'s dotted-path lookup. `-S` takes a **name or a literal host** (named lookup `<sel>.host`, else literal); no `-S` → `defaultHost` (else legacy `winHost`, else prompt→persist as `default`). `--save-as <name>` (+ `--default`) registers a host; `persist_host()`/`set_default_host()` merge into user config via jq (other tools' keys preserved). Same three output modes as pg (default ADO.NET `Integrated Security=true` string / `--sqlcmd` exec / `--export`). `scripts/fu-config.sh` is unchanged.
- **Settings-patching plugin** (`fu-statusline`): `statusLine` is **not** a plugin manifest key, and `${CLAUDE_PLUGIN_ROOT}` does not expand inside the user's `settings.json` — so the renderer cannot be run from the versioned plugin cache. `scripts/install.sh` copies `statusline.sh` to `~/.claude/statusline/` (a stable, version-free path), records the displaced `statusLine` in `previous-statusline.json` so uninstall restores rather than deletes, and rewrites `settings.json` atomically via jq. Both scripts are deterministic bash; the commands are thin wrappers. Install/uninstall recognise their own copy by the literal `fu-statusline` marker in the script header — **don't remove that token**. Paths come from `$HOME`/`$CLAUDE_CONFIG_DIR`/`$XDG_CACHE_HOME` only, which is what makes the test suite hermetic; there is deliberately no `fu-tools` config, since the layout is hardcoded.
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

It also ships a suite for the SessionStart session-id stamper (payload shape, the
marker wire format, silence on a missing id, and that a hostile id stays inert).
Hermetic with nothing to stub — the hook's only input is the JSON on stdin:

```bash
bash plugins/fu-dev-guards/test/stamp-session.test.sh
```

`fu-statusline` ships two plain-bash suites — the render contract and the `settings.json`
patching. Both are hermetic (`CC_SL_NOW` pins the clock, `XDG_CACHE_HOME` redirects the cache,
the install suite runs against a throwaway `$HOME`):

```bash
bash plugins/fu-statusline/test/statusline.test.sh
bash plugins/fu-statusline/test/install.test.sh
```

`fu-review-prs` ships two plain-bash suites — the posting-policy gate (COMMENT default,
`--auto-approve` opt-in, no flag leak across ticks) and the notifier (opt-in channels,
message content, failure paths, and that the webhook URL never reaches the log). Hermetic —
throwaway `$HOME` for both the state dir and the fu-tools config, `gh`/`git`/`curl` stubbed
on PATH, so nothing reaches GitHub or Teams:

```bash
bash plugins/fu-review-prs/test/auto-approve.test.sh
bash plugins/fu-review-prs/test/notify.test.sh
```

`fu-pg-stage` ships a suite for `connect.sh`'s `--export` failure contract — that a failed
mint eval's to a **non-zero** status with `PG*` untouched, that it emits `false` and never
`exit` (which would close the caller's shell), and that a successful export still round-trips
an awkward password through `sq()`. Hermetic: `vault` stubbed on PATH, throwaway `$HOME` for
the credential cache, cwd moved out of the repo so `fu-config.sh` resolves empty:

```bash
bash plugins/fu-pg-stage/test/export-guard.test.sh
```

Two harness gotchas cost time when writing it, both worth not rediscovering: `env "PATH=$empty" bash …`
fails because **`env` resolves `bash` through the new PATH** (use `"$BASH"`), and a password
containing a single quote cannot be interpolated into `bash -c "eval \"$OUT\""` — source the
export lines from a file instead.

## External dependencies (by plugin)

No package manager pulls these — they must be on PATH:
- `jq` — hard dependency of every hook, the config/DB scripts, and the `fu-statusline` renderer (which also shells out to `git`, and to nothing else).
- `gh` (authenticated for the target repo) — `fu-et-sweep`, `fu-review-prs`.
- `vault` (authenticated, `VAULT_ADDR` set) — `fu-pg-stage`; plus `psql` to actually connect.
- `sqlcmd` — `fu-mssql-stage`: on Windows the ODBC `sqlcmd` (v17/18) or `go-sqlcmd`; under WSL the **Windows-host `sqlcmd.exe`** on PATH (interop). No `vault`. `jq` only to persist the host.
- `node` — `fu-et-sweep` and its `node --test` suite.
- `python3` — `fu-ce-compound` frontmatter validator.
- `curl` — `fu-k8dash` (the only hard dep; `jq` optional, used for formatting); `fu-review-prs` only when a notification channel is configured.
- `pup` — `fu-datadog-pup` (a skill + a bundled `scripts/install-pup.sh` that installs/updates the binary) **and `fu-et-sweep`** (its sole Datadog access path since v0.2.0). The Datadog API CLI; authenticated via `pup auth login` or `DD_API_KEY`/`DD_APP_KEY`/`DD_SITE`.
- `wsl.exe`, PowerShell 7+, `winget` — `fu-wsl-setup` (Windows-host only; drives a Debian/Ubuntu WSL instance).

## Plugins

| Plugin | Kind | Purpose |
|---|---|---|
| fu-et-sweep | command + agents + scripts | Datadog Error Tracking → de-duped GitHub issues with root-cause writeups (Datadog via the `pup` CLI) |
| fu-log-sweep | command + agents + scripts | Datadog error-level Logs → de-duped GitHub issues with root-cause writeups; sibling to fu-et-sweep, dedups on a self-computed error signature (`type\|service\|top-app-frame` sha1) instead of an ET `issue_id` |
| fu-review-prs | command + scripts | PR review orchestrator (self-contained: bundles `lib.sh` + `review-task.md`; runtime state stays in `~/.claude/pr-review`, namespaced per repo). Comment-only by default — `--auto-approve` to approve clean PRs |
| fu-inspecting-orders-api | skill | Orders API inspection (config-resolved host + token) |
| fu-pg-stage | skill | Postgres via HashiCorp Vault credentials |
| fu-mssql-stage | skill | SQL Server via Windows (integrated) auth — `sqlcmd -E` native, or the Windows-host `sqlcmd.exe` under WSL (PATH interop); named hosts + default (`-S` name or literal), no Vault |
| fu-k8dash | skill | Read-only K8s inspection across clusters (stage/prod, pick with `-c`) via the k8dash dashboard's pass-through API proxy (GET-only, RBAC-bounded; user's OIDC bearer token) |
| fu-datadog-pup | skill | Query Datadog from the terminal with the `pup` CLI — logs/traces search, Error Tracking triage, auth/meta ops (pure-docs skill; no scripts/config) |
| fu-ce-compound | skill + agents | Document solved problems (EveryInc fork, MIT) |
| fu-dev-guards | hooks | Worktree path enforcement, protected-branch commit blocking, protected-directory edit + branch-switch blocking (forces worktrees), a SessionStart notice when a session opens in a protected checkout, a SessionStart session-id stamp for PR bodies, dotnet format pre-commit |
| fu-statusline | commands + scripts | Bash + jq Claude Code status line renderer — drop-in for `npx ccstatusline` (12.3 ms/11 MB vs 605 ms/103 MB per render). `/statusline-install` copies the renderer to `~/.claude/statusline/` and patches `settings.json`, because `statusLine` is **not** a plugin capability |
| fu-wsl-setup | skill | Provision a WSL work environment for Claude Code from Windows PowerShell 7+ — WSL version check, pick/create a Debian instance, then drive the full tool install sequence (non-interactive work automated, privileged/interactive steps handed to the user) |

`fu-et-sweep` reads Datadog Error Tracking through the **`pup` CLI** (run via Bash; see `fu-datadog-pup`) — **no bundled MCP server** as of v0.2.0 — plus the `gh` CLI authenticated for the target repo. Run it in a live session so `pup auth login` / `gh` auth is available (a `401` needs an interactive re-login). Key design wrinkle: `pup`'s ET `issues search` is a **thin projection (id + total_count only)**, so the orchestrator count-prunes then **gh-dedups first** to bound the set to ≤10, and only then hydrates each survivor via `pup error-tracking issues get` for the rich fields. **Regression is derived from a closed GitHub match** (GH is the sole regression authority — `pup` has no Datadog regression flag). The investigator pulls a sample stack via `pup traces/logs search '@issue.id:<id>'` (replacing the old `analyze_*` MCP tool). The pure-logic `sweep-lib.mjs` is shape-agnostic and was untouched by the cutover.
