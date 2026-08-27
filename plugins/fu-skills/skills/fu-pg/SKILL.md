---
name: fu-pg
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

Then log in. **LDAP is the method here** — a password login, no browser and no IdP
round-trip:

```bash
vault login -method=ldap username=<your-ldap-username>     # prompts for password
```

The token is cached in `~/.vault-token`, so you only re-login when it expires. Check
with `vault token lookup`; `display_name` names the method that minted it. A
non-interactive shell may not source your rc — if `VAULT_ADDR` is empty, export it
inline first.

**Report both policy sets when you check a token.** For a federated login `.data.policies`
is just `["default"]` and the grant that matters arrives via the identity's group mapping
in `.data.identity_policies`. Reading only the former makes a fully privileged token look
like it has no access:

```bash
vault token lookup -format=json | jq '{policies:.data.policies, identity_policies:.data.identity_policies}'
```

### If `-method=ldap` is rejected

Check the mount is really gone before believing it. `sys/internal/ui/mounts` is the
usual first look, but **it lists only mounts whose `listing_visibility` is `unauth`** —
the ones Vault advertises on the UI's login dropdown — and hidden is the *default*. A
live mount can be missing from that JSON, so absence there is not evidence of absence.
Stage is exactly this case: the listing returns only `oidc/`, yet `ldap/` works.

To actually prove a mount exists, probe **its own login path**. Vault's ACL check runs
before request-body validation, so an absent mount answers `403` no matter what you
send, while a mount that exists grades your payload — making **"not 403"** the existence
signal. Probe with a **throwaway username** and **no password field**. The username is
what matters: Vault's user-lockout counter (userpass/ldap, on by default since 1.13)
keys on the *account*, so any attempt this probe is charged for lands on a name nobody
owns rather than on yours. Omitting the password is a second-order courtesy — stage
rejects it before a successful bind, though the `500` suggests it still reached the
backend, so don't rely on it alone. **Never probe with your own username and a guessed
password.**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -d '{}' "$VAULT_ADDR/v1/auth/ldap/login/probeuser"
# 403 -> no such mount.  Anything else (stage answers 500) -> the mount is there.
```

The path must be one the mount actually serves: the ACL keys on the *full* path, so
probing something unrelated under the mount returns `403` whether or not the mount
exists, and tells you nothing. Use `auth/<mount>/login/<user>` for ldap/userpass.
Measured 2026-08-19, on a mount known to exist: `auth/ldap/login/probeuser` → `500`
(alive) while `auth/ldap/oidc/auth_url` → **`403`** (reads as "gone"). Same live mount,
opposite verdicts — the probe path, not the mount, decides what you conclude.

Dynamic Postgres usernames come back as `v-ldap-<user>-…` because the **database role's**
creation statement builds them — that is unrelated to how you logged in.

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
| Export `PG*` into shell | `eval "$(connect.sh <db-config> --export)"` — non-zero on failure |
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

## Troubleshooting

### Is Vault unreachable, or are you unauthenticated?

`vault token lookup` — and every `vault read` — fails the **same way** whether your
token expired or the host simply isn't routable. "Log in again" is therefore the
usual wrong first move. Discriminate before you touch auth:

```bash
getent hosts <vault-host>                   # does the name resolve at all?
curl -sS -m 8 "$VAULT_ADDR/v1/sys/health"   # can you reach it?
```

| What comes back | What it means |
|---|---|
| JSON (`initialized`, `sealed`, …) | Reachable — a `vault` failure really is auth. Re-login |
| `curl: (28) … timed out` | **Routing**, not auth. Your cached token may be perfectly valid |
| `curl: (6) Could not resolve host` | DNS — VPN or split-DNS down, or the host is wrong |
| HTTP `429` | **Standby node — healthy and reachable**, not rate limiting. `sys/health` returns `429` for "unsealed but standby" by design (`200` = active, `473` = perf standby, `503` = sealed, `501` = uninitialized). Read the body: `standby: true` confirms it. Treat exactly like `200` |
| HTTP `403` | Genuinely reachable and answering — this one *is* permissions |

A host that **resolves but times out** is the signature of an internal service
reachable only over the corporate VPN.

Note the status codes here are **`sys/health`'s own vocabulary**, not generic HTTP —
which is why `429` is a health state rather than a rate limit. Measured on stage
2026-08-19: `429` with `{"initialized":true,"sealed":false,"standby":true}`.

### WSL2: resolves but times out (the VPN's routes aren't shared)

Under WSL2's default NAT networking the Windows VPN client's routes are not
propagated into the distro, so internal hosts resolve and then hang. Confirm the
split by asking the **Windows** curl the identical question:

```bash
curl -sS -m 8 "$VAULT_ADDR/v1/sys/health"                              # (28) timeout
/mnt/c/Windows/System32/curl.exe -sS -m 8 "$VAULT_ADDR/v1/sys/health"  # succeeds
```

Windows succeeding where WSL times out means the **route** is missing, not Vault.
Fix by running [`wsl-vpnkit`](https://github.com/sakai135/wsl-vpnkit) from a Windows
terminal and leaving it running:

```powershell
wsl -d wsl-vpnkit --cd /app wsl-vpnkit
```

`ip route` inside the distro should then show `default via 192.168.127.1 dev wsltap`
rather than an `eth0` default. (Mirrored networking — `networkingMode=mirrored` in
`.wslconfig` — is the other way to fix it.)

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
  `vault login`. Set `VAULT_ADDR` first — and before re-logging in, check the failure
  isn't really *unreachable* (see Troubleshooting); the two are indistinguishable from
  the `vault` CLI alone.
- **Trusting the exit status of a command substitution.** Every failure here writes to
  stderr and **nothing to stdout**, so the fail-open is silent: psql falls back to the
  local unix socket and the error reads as "the server is down" when the truth is "you
  were never connected". `--export` now guards itself — it emits a `false` on failure,
  so `eval "$(connect.sh … --export)"` returns non-zero and leaves `PG*` untouched. The
  **connection-string mode cannot** self-guard, because its stdout is a URI rather than
  shell code. Capture and check it:

  ```bash
  conn=$(connect.sh <db-config>) || return 1   # NOT  psql "$(connect.sh <db-config>)"
  psql "$conn"
  ```

  The tell for having hit this: `psql: … connection to server on socket
  "/var/run/postgresql/.s.PGSQL.5432" failed` — a *local socket* path, when you asked
  for a remote host.
- **Reading `sys/internal/ui/mounts` as a complete list.** It shows only mounts marked
  `listing_visibility: unauth`, and hidden is the default — so a live method can be
  missing from it. Stage's `ldap/` is exactly this case: the listing names only `oidc/`,
  yet `-method=ldap` works. Absence there is not absence; probe `auth/<mount>/login/<user>`
  before declaring a method dead (see Authenticate).
