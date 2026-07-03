---
name: mssql-stage
description: Use when connecting to a SQL Server / MSSQL database with Windows (integrated) authentication — natively on Windows via sqlcmd, or under WSL via the Windows-host sqlcmd.exe reached through PATH interop. Hosts are named in config with a default; -S takes a name or a literal host. Triggers — "connect to mssql", "sql server windows auth", "sqlcmd via wsl", "query the sql server", "integrated auth mssql".
---

# SQL Server via Windows authentication

## Overview

Every SQL Server we reach uses **Windows (integrated) authentication** — no SQL
logins, no Vault. `connect.sh` chooses the mechanism from the platform:

| Platform     | How                                | Auth                            |
|--------------|------------------------------------|---------------------------------|
| Windows      | `sqlcmd -E`                        | integrated (Kerberos, NTLM fb.) |
| WSL          | `sqlcmd.exe -E` via PATH interop   | integrated over NTLM            |
| Linux / macOS| not supported — errors out         | —                               |

Under WSL the **Windows-host `sqlcmd.exe`** is used (reached by name through WSL's
PATH interop), because the Linux `go-sqlcmd` has no NTLM support and most of these
servers have no Kerberos SPN — so only the Windows client authenticates. `-C`
(trust server certificate) is always passed; internal servers use self-signed certs.

## Hosts: named, with a default

Hosts are **named** in config (like `fu-k8dash` clusters), with one marked default:

```jsonc
"mssql-stage": {
  "defaultHost": "stage",
  "stage":  { "host": "ldmstagedb.example.com" },
  "idp-ro": { "host": "auawsro.example.com" }
}
```

`-S` accepts a **name or a literal host**, resolved in order:

1. `-S <name>` → that host's `mssql-stage.<name>.host`,
2. `-S <host>` → used **literally** when it matches no configured name (e.g. anything with dots),
3. no `-S` → the `mssql-stage.defaultHost` name (else a legacy single `winHost`),
4. nothing configured → `connect.sh` **prompts** and persists it as `default`.

Register / re-point (writes to `~/.claude/fu-tools/config.json`):

```bash
connect.sh -S db.example.com --save-as qa            # add a named host 'qa'
connect.sh -S db.example.com --save-as qa --default  # ...and make it the default
connect.sh -S idp-ro --default                       # point default at an existing name
```

## Quick reference

| Want                                   | Command                                        |
|----------------------------------------|------------------------------------------------|
| ADO.NET string (default host)          | `connect.sh`                                   |
| ...against a named host                | `connect.sh -S idp-ro`                         |
| ...for a specific database             | `connect.sh My.Db`                             |
| Open a sqlcmd shell                    | `connect.sh My.Db --sqlcmd`                    |
| Run one query                          | `connect.sh My.Db --sqlcmd -- -Q "SELECT 1"`  |
| Export SQLCMD* into the shell          | `eval "$(connect.sh My.Db --export)"`          |
| Register a named host                  | `connect.sh -S db.example.com --save-as qa`    |
| ...and make it the default             | `connect.sh -S db.example.com --save-as qa --default` |

Everything after `--` is passed straight through to sqlcmd.

## Prerequisites

- **Windows:** `sqlcmd` on PATH (ODBC `sqlcmd` v17/18 or `go-sqlcmd`).
- **WSL:** `sqlcmd` installed **on Windows**, plus WSL PATH interop enabled (the
  default) so `sqlcmd.exe` resolves by name. Verify: `command -v sqlcmd.exe`.
- `jq` — only needed to persist the host to config.
- You must be signed into Windows with a domain account the SQL Server authorises.

## Common mistakes

- **Using the Linux `sqlcmd` under WSL.** It cannot do Windows auth (no NTLM) — you
  get `Login failed for user ''`. The script deliberately calls `sqlcmd.exe`.
- **Expecting it on a plain Linux / CI box.** No Windows session, no Windows auth.
- **Fighting shell quoting on queries.** Use `--sqlcmd -- -Q "..."`; the `--` hands
  the remainder to sqlcmd untouched.
- **The UNC-cwd warning under WSL.** Harmless; the script `cd`s to a Windows dir first.

## Why NTLM, not Kerberos

Windows integrated auth tries Kerberos, then falls back to NTLM. Many of these hosts
are read-routed availability-group / alias names with **no registered SPN**, so the
KDC cannot issue a service ticket and Windows silently uses NTLM. Linux clients have
no NTLM fallback — which is exactly why the connection must go through the Windows
`sqlcmd.exe`.
