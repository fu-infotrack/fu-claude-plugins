---
name: pg-stage
description: Use when connecting to a Postgres database whose credentials live in HashiCorp Vault's database secrets engine — read the database config for the connection and the roles it allows, mint dynamic short-lived credentials from a role, and build a connection string. Covers any Vault-managed Postgres; host/db/role resolve from fu-tools config. Triggers — "connect to stage db", "vault db creds", "psql via vault", "generate database credentials".
---

# Postgres via Vault (database secrets engine)

## Overview

When a Postgres database is managed by Vault's **database secrets engine**, you
don't hold static credentials. You start from the **database config**, find the
**roles** it allows, then have a role mint **dynamic, short-lived credentials**.
The config also carries the `connection_url` (host/port/dbname). Assemble the two.

The flow, always config-first:

```
<mount>/config/<db>   →  connection_url  +  allowed_roles[]
        │                                        │
        │                                  pick a role
        ▼                                        ▼
   HOST:PORT/DB                      <mount>/creds/<role>  →  username + password (lease)
        └──────────────── connection string ───────────────┘
```

`<mount>` is the secrets-engine mount path, default `database`.

**Config-resolved values** (via `${CLAUDE_PLUGIN_ROOT}/scripts/fu-config.sh pg-stage <key>`,
falling back to env / CLI args):

| Key | Meaning |
|-----|---------|
| `vaultAddr` | the Vault server URL (also honoured via `$VAULT_ADDR`) |
| `dbConfig` | the database config name read at `<mount>/config/<dbConfig>` |
| `role` | the role to mint creds from (optional — auto-picked if the config allows exactly one) |
| `mount` | secrets-engine mount path (default `database`) |

**Credentials are ephemeral, but cached.** Every `creds/<role>` read mints a fresh
user/password with a lease. To avoid minting a new login on every call, `connect.sh`
caches the minted cred in a user-only `0600` file under `~/.claude/fu-tools/cache/pg-stage/`
and reuses it until ~5 min before the lease expires, then auto-re-mints. A cache hit
skips both Vault reads (config + creds). `--fresh` forces a new mint; `--purge` wipes
the cache. The cache holds a plaintext password — never commit it; it is bounded by the
lease and self-expires.

## Prerequisites

- `vault` CLI — install per <https://developer.hashicorp.com/vault/install>
  (e.g. `sudo apt install vault` after adding HashiCorp's apt repo, or `brew install hashicorp/tap/vault`). Then authenticate (see below).
- `psql` (postgresql-client) — needed for `--psql` and to actually connect
  (e.g. `sudo apt install postgresql-client`, or `brew install libpq`).
- `jq` for parsing JSON output (`sudo apt install jq` / `brew install jq`).

### Authenticate

`VAULT_ADDR` must point at the Vault server, then log in. Resolve it from config or
set it yourself:

```bash
export VAULT_ADDR="$("${CLAUDE_PLUGIN_ROOT}/scripts/fu-config.sh" pg-stage vaultAddr)"
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
no `<db-config>` arg it falls back to the resolved `pg-stage.dbConfig`; role falls back
to `pg-stage.role`.

| Want | Command |
|------|---------|
| Connection string (config db + auto/config role) | `connect.sh` |
| Explicit db-config | `connect.sh <db-config>` |
| Explicit role | `connect.sh <db-config> <role>` |
| Open psql shell | `connect.sh <db-config> --psql` |
| Export `PG*` into shell | `eval "$(connect.sh <db-config> --export)"` |
| Non-default mount | `connect.sh <db-config> --mount <mount>` |
| Bypass cache, mint fresh | `connect.sh --fresh` |
| Purge cached credentials | `connect.sh --purge` |

If the config allows exactly one role it's used automatically; if it allows several
and you didn't name one (or set `pg-stage.role`), the script lists them and stops so
you can pick.

## Manual steps (what the script does)

Use `-format=json` + `jq` — never scrape the table output, column widths shift.

```bash
mount=database; db=<dbConfig>            # db from pg-stage.dbConfig if unset

# 1. config: connection_url + the roles this DB allows
cfg=$(vault read -format=json "$mount/config/$db")
url=$(jq -r '.data.connection_details.connection_url' <<<"$cfg")
jq -r '.data.allowed_roles[]' <<<"$cfg"          # choose one

# 2. mint dynamic creds from the chosen role
role=<role>                              # role from pg-stage.role or auto-picked
creds=$(vault read -format=json "$mount/creds/$role")
user=$(jq -r '.data.username' <<<"$creds")
pass=$(jq -r '.data.password' <<<"$creds")
lease=$(jq -r '.lease_duration' <<<"$creds")     # seconds until creds die

# 3. connection_url => postgresql://{{username}}:{{password}}@HOST:PORT/DB?params
#    strip everything before '@', substitute the dynamic creds
```

## Common Mistakes

- **Skipping the config read.** The config is the source of truth for both the host
  and the *allowed roles* — don't guess a role name, read `allowed_roles`.
- **Parsing the table output.** Use `-format=json` + `jq`; the key/value table is not
  machine-stable.
- **Treating cached creds as permanent.** The cache is lease-bounded and auto-re-mints
  near expiry; if a cred is revoked early, run `--fresh`. Never commit the cache files.
- **Dropping query params.** The `connection_url` often carries `?sslmode=require`;
  keep it on the assembled string.
- **Wrong mount.** If the engine isn't mounted at `database`, pass `--mount`.
- **Not authenticated.** `vault read` fails with 403 / "missing client token" without
  `vault login`. Set `VAULT_ADDR` first.
