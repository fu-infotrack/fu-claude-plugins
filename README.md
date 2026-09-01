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
| fu-skills | skills + agents + scripts | All scenario skills in one plugin (see table below). `fu-pg` and `fu-pup` auto-trigger; the rest are `disable-model-invocation: true` — zero context until invoked as `/fu-*`. `/ask-fu` is the catalogue/router |
| fu-copilot | skill + agent + scripts | Delegate a task to GitHub Copilot CLI and verify what it actually did. Detached dispatch (runs take 10-113 min), `kill -0` wait, then git-based checks — because a self-report is not a completion signal |
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

`fu-tools` config keys are **unchanged** by the consolidation: still `pg-stage`,
`mssql-stage`, `k8dash`, `inspecting-orders-api` — the scripts kept their tool
names, so no config migration is needed.
