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
| review-prs | command + scripts | PR review orchestrator (self-contained; runtime state in ~/.claude/pr-review, per-repo) |
| inspecting-orders-api | skill | Orders API inspection |
| pg-stage | skill | Postgres via Vault (psql; caches dynamic creds) |
| mssql-stage | skill | SQL Server via Windows (integrated) auth (`sqlcmd`; Windows-host `sqlcmd.exe` under WSL; named hosts + default, `-S` name or literal) |
| k8dash | skill | Read-only K8s inspection across clusters (stage/prod, pick with `-c`) via the k8dash API proxy (GET-only, user's OIDC token) |
| datadog-pup | skill | Query Datadog from the terminal with the `pup` CLI — logs/traces search, Error Tracking triage, auth/meta ops |
| ce-compound | skill + agents | Document solved problems (EveryInc fork, MIT) |
| dev-guards | hooks | Worktree path enforcement, protected-branch commit blocking, protected-directory edit + branch-switch blocking, dotnet format pre-commit |
| wsl-setup | skill | Provision a WSL Debian work environment for Claude Code from Windows PowerShell 7+ (WSL/disk preflight, named instance, tool inventory + full install; non-interactive steps automated, credential logins handed off) |
