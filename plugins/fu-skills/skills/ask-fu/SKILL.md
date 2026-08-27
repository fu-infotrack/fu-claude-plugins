---
name: ask-fu
description: Catalogue and router for the /fu-* scenario skills. Invoke when the user can't remember which fu- skill they need — it names the right one and hands the task to it.
disable-model-invocation: true
---

# ask-fu — which fu- skill do I need?

Every fu- scenario skill is hidden from the model's context
(`disable-model-invocation: true`) and invoked explicitly by name. This skill is
the index: match the user's ask to a row, then **invoke that skill via the Skill
tool** (`fu-skills:<name>`) and carry the user's original request into it. Don't
answer from this table alone — the target skill holds the actual instructions.

| Skill | Scenario | Typical asks |
|---|---|---|
| `fu-pg` | Postgres whose credentials live in HashiCorp Vault's database secrets engine — mint dynamic creds, build a connection string | "connect to stage db", "vault db creds", "psql via vault" |
| `fu-mssql` | SQL Server via Windows integrated auth — `sqlcmd -E` native, or Windows-host `sqlcmd.exe` under WSL; named hosts + default | "connect to mssql", "sql server windows auth", "query the sql server" |
| `fu-k8` | Read-only Kubernetes inspection across clusters (stage/prod via `-c`) through the k8dash dashboard's pass-through API proxy — GET-only, user's OIDC token | "check the pods", "what's deployed on stage", "k8s logs for <service>" |
| `fu-pup` | Query Datadog from the terminal with the `pup` CLI — logs/traces search, Error Tracking triage, auth/meta ops | "search datadog logs", "pup auth", "error tracking triage" |
| `fu-order` | Inspect the Orders API (config-resolved host + token) | "inspect an order", "query the orders api" |
| `fu-wsl` | Provision a WSL work environment for Claude Code from Windows PowerShell 7+ | "set up wsl", "new wsl instance", "provision a dev environment" |
| `fu-ce` | Document a recently solved problem to compound team knowledge (EveryInc fork) | "document this fix", "write up what we solved" |

If nothing fits, say so — don't force the nearest match. If two could fit
(e.g. a database question that could be `fu-pg` or `fu-mssql`), ask which engine
rather than guessing.

Related but separate (not routed from here): `/review-prs` (PR-review loop),
`/et-sweep` and `/log-sweep` (Datadog → GitHub issue sweeps),
`/statusline-install` (status line renderer).
