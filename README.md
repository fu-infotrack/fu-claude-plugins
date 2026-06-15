# fu-claude-plugins

Personal Claude Code marketplace. Per-tool plugins; install at user scope.

## Config resolution

Tools resolve concrete values via precedence:
`CLI flags > nearest <ancestor>/.claude/.fu-tools.json > auto-detect (git remote, k8_settings app_name) > ~/.claude/fu-tools/config.json > defaults`.

Project file shape: `{ "<tool>": { ... } }`. See each plugin's README.

## Plugins

| Plugin | Kind | Purpose |
|---|---|---|
| et-sweep | command + agents + scripts + MCP | Datadog Error Tracking -> GitHub issues |
| review-prs | command | PR review orchestrator |
| inspecting-orders-api | skill | Orders API inspection |
| pg-stage | skill | Postgres via Vault |
| ce-compound | skill + agents | Document solved problems (EveryInc fork, MIT) |
