# fu-claude-plugins

Personal Claude Code marketplace. Per-tool plugins; install at user scope.

## Config resolution

Tools resolve concrete values via precedence:
`CLI flags > nearest <ancestor>/.claude/.fu-tools.json > auto-detect (git remote, k8_settings app_name) > ~/.claude/fu-tools/config.json > defaults`.

Project file shape: `{ "<tool>": { ... } }`. See each plugin's README.

## Plugins

| Plugin | Kind | Purpose |
|---|---|---|
| et-sweep | command + agents + scripts | Datadog Error Tracking -> GitHub issues (via the `pup` CLI) |
| fu-log-sweep | command + agents + scripts | Datadog error-level **Logs** → de-duped GitHub issues with root-cause writeups; dedups on a computed error signature (no Error Tracking required) |
| review-prs | command + scripts | PR review orchestrator (self-contained; runtime state in ~/.claude/pr-review, per-repo). Comment-only by default; `--auto-approve` to approve clean PRs |
| fu-skills | skills + agents + scripts | All scenario skills in one plugin (see table below). `fu-pg` and `fu-pup` auto-trigger; the rest are `disable-model-invocation: true` — zero context until invoked as `/fu-*`. `/ask-fu` is the catalogue/router. Also bundles the `copilot` agent |
| dev-guards | hooks | Worktree path enforcement, protected-branch commit blocking, protected-directory edit + branch-switch blocking, a session-start notice when opened in a protected checkout, a session-id stamp for PR bodies, dotnet format pre-commit |
| statusline | commands + scripts | Bash + jq status line renderer — drop-in for `npx ccstatusline` at 49x less time / 9x less memory per render; `/statusline-install` patches `settings.json` (statusLine is not a plugin capability) |

### fu-skills — the scenario-skill bundle

| Skill | In context? | Purpose |
|---|---|---|
| /fu-pg | yes (auto-triggers) | Postgres via Vault (psql; caches dynamic creds) |
| /fu-pup | yes (auto-triggers) | Query Datadog from the terminal with the `pup` CLI — logs/traces search, Error Tracking triage, auth/meta ops |
| /fu-mssql | hidden | SQL Server via Windows (integrated) auth (`sqlcmd`; Windows-host `sqlcmd.exe` under WSL; named hosts + default, `-S` name or literal) |
| /fu-k8 | hidden | Read-only K8s inspection across clusters (stage/prod, pick with `-c`) via the k8dash API proxy (GET-only, user's OIDC token) |
| /fu-order | hidden | Orders API inspection |
| /fu-wsl | hidden | Provision a WSL Debian work environment for Claude Code from Windows PowerShell 7+ (WSL/disk preflight, named instance, tool inventory + full install; non-interactive steps automated, credential logins handed off) |
| /fu-ce | hidden | Document solved problems (EveryInc fork, MIT); ships the ce-* review agents |
| /ask-fu | hidden | Catalogue/router — invoke when you can't remember which /fu-* skill you need |

It also bundles agents, which are addressed as `@fu-skills:copilot` /
`@fu-skills:ce-*` once the plugin is installed:

| Agent | Purpose |
|---|---|
| copilot | Runs a task through GitHub Copilot CLI (`gpt-5.6-luna`), saving the reply to disk and returning a 4-line receipt |
| ce-* | The four `/fu-ce` review agents (security, performance, data integrity, simplicity) |

`copilot` is a **thin executor — the caller owns both paths, the agent only runs it.** Hand it
a task (inline, or the absolute path to a task file you wrote) plus an absolute output path.
Put both in `$CLAUDE_JOB_DIR/tmp` if that is set, else `$(mktemp -d)` — never in the working
tree, which no repo git-ignores. The agent is told not to author or reword the task, so the
output contract you write reaches Copilot byte-exact.

It returns a **receipt, not the reply** — `STATUS` / `OUTPUT` / `BYTES` / `VERDICT`, four lines
— and Copilot's full response stays in the output file. That keeps the calling session's
context bounded regardless of how much Copilot writes, which is the whole point of delegating;
read the file (partially, with `sed -n` or `grep`) only when you need the detail. `VERDICT` is
the sub-agent's own paraphrase, so treat the file as the source of truth.

`fu-tools` config keys are **unchanged** by the consolidation: still `pg-stage`,
`mssql-stage`, `k8dash`, `inspecting-orders-api` — the scripts kept their tool
names, so no config migration is needed.
