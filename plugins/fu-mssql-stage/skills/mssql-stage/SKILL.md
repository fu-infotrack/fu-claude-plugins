---
name: mssql-stage
description: Use when connecting to a SQL Server / MSSQL database whose credentials live in HashiCorp Vault's database secrets engine — read the database config for the connection and the roles it allows, mint dynamic short-lived credentials from a role, and build a connection. Covers any Vault-managed SQL Server; host/db/role resolve from fu-tools config. Triggers — "connect to stage mssql", "sql server vault creds", "sqlcmd via vault", "generate database credentials".
---

# SQL Server via Vault (database secrets engine)

## Overview

When a SQL Server database is managed by Vault's **database secrets engine**, you
don't hold static credentials. You start from the **database config**, find the
**roles** it allows, then have a role mint **dynamic, short-lived credentials**.
The config also carries the `connection_url` (an ADO.NET string with Server/Database).
Assemble the two.

The flow, always config-first:

```
<mount>/config/<db>   →  connection_url  +  allowed_roles[]
        │                                        │
        │                                  pick a role
        ▼                                        ▼
   Server / Database                 <mount>/creds/<role>  →  username + password (lease)
        └──────────────── connection / sqlcmd ──────────────┘
```

`<mount>` is the secrets-engine mount path, default `database`.

**The `connection_url` is an ADO.NET connection string**, not a URI:

```
Server=stage-mssql.example.com;Database=My.Db;User Id={{username}};Password={{password}};TrustServerCertificate=true;
```

Vault stores it percent-encoded; `connect.sh` decodes it, parses `Server=` (the whole
`[tcp:]host[\instance][,port]` spec, passed to `sqlcmd -S` verbatim) and `Database=`,
and maps `TrustServerCertificate=true` → `-C`, `Encrypt=true` → `-N`. The `{{username}}` /
`{{password}}` placeholders are filled from the minted creds.

**Config-resolved values** (via `${CLAUDE_PLUGIN_ROOT}/scripts/fu-config.sh mssql-stage <key>`,
falling back to env / CLI args):

| Key | Meaning |
|-----|---------|
| `vaultAddr` | the Vault server URL (also honoured via `$VAULT_ADDR`) |
| `dbConfig` | the database config name read at `<mount>/config/<dbConfig>` |
| `role` | the role to mint creds from (optional — auto-picked if the config allows exactly one) |
| `mount` | secrets-engine mount path (default `database`) |

**Credentials are ephemeral.** Every `creds/<role>` read mints a fresh user/password
with a lease (here ~24h). When the lease expires the login stops working — re-read.
Never cache or commit them.

## Prerequisites

- `vault` CLI — install per <https://developer.hashicorp.com/vault/install>
  (e.g. `sudo apt install vault` after adding HashiCorp's apt repo, or `brew install hashicorp/tap/vault`). Then authenticate (see below).
- `sqlcmd` — the Go rewrite (`go-sqlcmd`, `sqlcmd -?` reports `Version v1.x`). Install
  per <https://github.com/microsoft/go-sqlcmd> (`go install github.com/microsoft/go-sqlcmd/cmd/modern@latest`,
  or `winget install sqlcmd`, or the Linux package). Needed for `--sqlcmd` and to actually connect.
- `jq` for parsing JSON output (`sudo apt install jq` / `brew install jq`).

### Authenticate

`VAULT_ADDR` must point at the Vault server, then log in. Resolve it from config or
set it yourself:

```bash
export VAULT_ADDR="$("${CLAUDE_PLUGIN_ROOT}/scripts/fu-config.sh" mssql-stage vaultAddr)"
# or set it directly:  export VAULT_ADDR="https://your-vault.example.com"
```

Persist it once in your shell rc so every session has it (`echo 'export VAULT_ADDR=...' >> ~/.zshrc`).

Then log in:

```bash
vault login -method=ldap username=<your-ldap-username>     # prompts for password
```

LDAP is a common method (dynamic users come back as `v-ldap-<user>-…`); use whatever
method your Vault is configured for. The token is cached in `~/.vault-token`, so you
only re-login when it expires. Check with `vault token lookup`. A non-interactive
shell may not source your rc — if `VAULT_ADDR` is empty, export it inline first.

## Quick Reference

`connect.sh` (this skill dir) runs the whole config → role → creds → conn flow. With
no `<db-config>` arg it falls back to the resolved `mssql-stage.dbConfig`; role falls back
to `mssql-stage.role`.

| Want | Command |
|------|---------|
| ADO.NET connection string (config db + auto/config role) | `connect.sh` |
| Explicit db-config | `connect.sh <db-config>` |
| Explicit role | `connect.sh <db-config> <role>` |
| Open sqlcmd shell | `connect.sh <db-config> --sqlcmd` |
| Export `SQLCMD*` into shell | `eval "$(connect.sh <db-config> --export)"` |
| Non-default mount | `connect.sh <db-config> --mount <mount>` |

After `--export`, `sqlcmd -Q "SELECT @@VERSION"` uses the exported `SQLCMD*` env — no
need to repeat `-S/-d/-U/-P`.

If the config allows exactly one role it's used automatically; if it allows several
and you didn't name one (or set `mssql-stage.role`), the script lists them and stops so
you can pick.

## Manual steps (what the script does)

Use `-format=json` + `jq` — never scrape the table output, column widths shift.

```bash
mount=database; db=<dbConfig>            # db from mssql-stage.dbConfig if unset

# 1. config: connection_url (ADO.NET string) + the roles this DB allows
cfg=$(vault read -format=json "$mount/config/$db")
url=$(jq -r '.data.connection_details.connection_url' <<<"$cfg")   # percent-encoded
jq -r '.data.allowed_roles[]' <<<"$cfg"          # choose one

# 2. mint dynamic creds from the chosen role
role=<role>                              # role from mssql-stage.role or auto-picked
creds=$(vault read -format=json "$mount/creds/$role")
user=$(jq -r '.data.username' <<<"$creds")
pass=$(jq -r '.data.password' <<<"$creds")       # ~24h lease

# 3. parse Server= / Database= from the (URL-decoded) ADO string, then:
SQLCMDPASSWORD="$pass" sqlcmd -S <Server> -d <Database> -U "$user" -C
```

## Common Mistakes

- **Treating connection_url as a URI.** It's an ADO.NET `key=value;…` string. Parse
  `Server=` and `Database=`; don't `${url#*@}` it like a `postgresql://` URI.
- **Forgetting it's percent-encoded.** Vault returns `User%20Id=%7B%7B…`. Decode before
  parsing (the script does).
- **Skipping the config read.** The config is the source of truth for both the Server
  and the *allowed roles* — don't guess a role name, read `allowed_roles`.
- **Parsing the table output.** Use `-format=json` + `jq`; the key/value table is not
  machine-stable.
- **Caching creds.** They expire with the lease. Re-mint each session; never commit.
- **Dropping TLS options.** `TrustServerCertificate=true` → `sqlcmd -C`; without it a
  self-signed cert fails the handshake. `Encrypt=true` → `-N`.
- **Wrong mount.** If the engine isn't mounted at `database`, pass `--mount`.
- **Not authenticated.** `vault read` fails with 403 / "missing client token" without
  `vault login`. Set `VAULT_ADDR` first.
- **Old `sqlcmd`.** The ODBC `sqlcmd` (v17/18) differs in flag handling; this skill
  targets the Go `go-sqlcmd` (`sqlcmd -?` → `Version v1.x`).
