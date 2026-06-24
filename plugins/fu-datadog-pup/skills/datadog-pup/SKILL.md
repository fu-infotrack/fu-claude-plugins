---
name: datadog-pup
description: Use when querying Datadog from the terminal with the `pup` CLI — searching or counting logs, searching/aggregating APM traces (spans), triaging Error Tracking issues, or running auth/meta ops (OAuth `pup auth login`, `auth status`, picking a site/org). Reach for this when a Datadog lookup is needed from the shell, or when a pup call returns 401 (re-auth) or 403 (missing scope).
---

# Querying Datadog with the `pup` CLI

`pup` is the Datadog API CLI (Rust) — OAuth2 (`pup auth login`) or API keys
(`DD_API_KEY` + `DD_APP_KEY` + `DD_SITE`), covering 30+ API domains. This skill
covers the read paths we actually use: **logs**, **traces**, **error-tracking**,
and the **auth/meta** ops around them. Everything here is read-only; pup also has
write/manage verbs (gated behind scopes) that are out of scope.

The exhaustive flag list for any command is one call away — don't guess:

```bash
pup <domain> <command> --help        # human-readable flags + examples
pup agent schema --compact --no-agent # JSON map of every command + its flags
```

## Agent mode — the output envelope (read this first)

pup **auto-detects** that it's being driven by an AI coding assistant and switches
to *agent mode*, which wraps every response in an envelope:

```jsonc
{ "status": "...", "data": <the real payload>, "metadata": { ... } }
```

So when **you** (the agent) run pup, read the answer from `.data`. Two consequences:

- **Authoring a script/alias/runbook the user or CI will run** → append `--no-agent`
  so the script sees the **raw** payload (no envelope), matching what runs in their
  shell. A script written without `--no-agent` will parse a different shape than it
  gets at runtime. `pup --no-agent logs search --query=… | jq '.[].attributes'`.
- Force either way with `--agent` / `--no-agent` (overrides auto-detection).

`--output json|table|yaml|csv` (default json) and `--jq '<expr>'` (filter before
formatting) are global. Prefer narrowing at the API (`--query`, `--group-by`) over
piping big JSON through jq.

**`--jq` runs on the *payload*, not the envelope** — and the payload shape differs
per domain, so the right root expression changes:

| domain | payload shape | `--jq` root |
|---|---|---|
| `logs search` / `traces search` | a bare array | `.[]` |
| `error-tracking issues search` | JSON:API object | `.data[]` |
| `error-tracking issues get` | JSON:API object | `.data` (single) |

Writing `.data[]` against a logs/traces response (or `.[]` against an ET one)
silently yields nothing. When unsure, run once with no `--jq` and look at the
top-level shape. (The envelope's `status`/`data`/`metadata` is *outside* what `--jq`
sees — don't reach for it there.)

## Auth & meta ops

```bash
pup auth status            # authed? which site, scopes, seconds to token expiry
pup auth login             # OAuth2 in the browser (opens a callback on :8000/8080/8888/9000)
pup auth login --ro        # request read-only scopes only (a.k.a. --read-only)
pup auth login --site ap2.datadoghq.com   # pick the Datadog site (AU = ap2.datadoghq.com)
pup auth list              # all stored org sessions
pup auth refresh           # refresh the access token without a full re-login
pup auth logout
pup auth test              # verify connection + credentials
```

- **Site**: AU org is `ap2.datadoghq.com`. Set per-login with `--site`, or via
  `DD_SITE`. US1 is `datadoghq.com` (default), EU `datadoghq.eu`, etc.
- **Multi-org**: `--org <name>` selects a named session; first set it up with
  `pup auth login --org <name>` (optionally `--org-uuid <uuid>` to pre-route SSO).
- **401** from any command → token expired/invalid → `pup auth refresh` (or
  `pup auth login`). **403** → authenticated but the scope/permission is missing;
  re-login with the needed scopes (`--scopes a,b,c`) — refreshing won't help.

## Logs

```bash
# Search (v1) — fast, --query is REQUIRED. Always pass --from.
pup logs search --query 'service:orders-api status:error' --from 1h --limit 50

# Count / stats WITHOUT pulling raw logs (cheap; this is the right way to count):
pup logs aggregate --query 'service:orders-api status:error' --from 4h \
  --compute count --group-by service,status

# v2 search (richer paging/cursors):
pup logs query --query 'service:orders-api @http.status_code:500' --from 1h
```

- `logs search` (v1) vs `logs query`/`logs list` (v2) — both search; v2 is the
  newer API. Start with `logs search` for ad-hoc triage.
- `--compute` accepts `count,avg(@field),percentile(@field,95)`; `--group-by`
  takes comma-separated facets (`service,status,@http.status_code`).
- `--storage indexes|online-archives|flex`, `--index <names>`, `--sort asc|desc`.

## Traces (APM spans)

```bash
pup traces search --query 'service:orders-api resource_name:"POST /orders"' --from 1h --limit 50
pup traces aggregate --query 'service:orders-api' --from 1h \
  --compute 'count,percentile(@duration,95)' --group-by resource_name
```

- **APM durations are in NANOSECONDS** — `@duration:>1000000000` is 1s, not 1ns.
  Don't assume seconds/ms when filtering or reading values.
- `--query` defaults to `*`. Same `--compute`/`--group-by` shape as logs aggregate.

## Error Tracking

```bash
# Search issues — --track is effectively required (see below). Filter on jq with .data[]:
pup error-tracking issues search --query 'service:orders-api' \
  --track trace --state OPEN --order-by TOTAL_COUNT --from 7d \
  --jq '.data[] | {id, type:.attributes.error_type, count:.attributes.total_count}'

pup error-tracking issues get <ISSUE_ID>     # full detail for one issue (payload: .data)
```

- **`--track` and `--persona` are mutually exclusive, and you must pass exactly one**
  — omit both and the command errors "required arguments were not provided"; pass both
  and it errors "cannot be used with". Pick the source track (`--track trace|logs|rum`)
  for backend triage; use `--persona ALL|BROWSER|MOBILE|BACKEND` instead when slicing
  by client.
- Other filters: `--state OPEN|ACKNOWLEDGED|RESOLVED|IGNORED|EXCLUDED`,
  `--order-by TOTAL_COUNT|FIRST_SEEN|IMPACTED_SESSIONS|PRIORITY`,
  `--team <uuid>` / `--assignee <uuid>`.
- **`issues search` returns a thin projection** (many `attributes` are null); use
  `issues get <ID>` for the real `error_type` / `function_name` / `file_path` /
  `first_seen` etc.

### The source track shapes how you correlate (and what to instrument)

Every issue has a **source track** — it was captured from a `trace`, a `log`, or
`rum`. This dictates where the supporting evidence lives:

- A **trace-sourced** issue has **no matching error log** — don't hunt logs for it.
  Pivot via `pup traces search`. And note error spans are **sampled + retention-bound**:
  a low-count issue from days ago often has *no retrievable span left*, so `traces
  search @error.type:…` legitimately returns 0 even though `issues get` still shows it.
  Correlate instead by the surrounding `info` logs at the issue's `first_seen`/`last_seen`
  timestamp to reconstruct what the service was doing.
- **App-side takeaway:** if an error you care about is only trace-sourced (so it
  vanishes from logs and from APM once sampled), make the app surface it deliberately —
  emit a structured **error-level log** (with `error.type`/`message`/`stack`) or an
  explicit span error at the catch site — so it stays queryable and correlatable rather
  than depending on trace retention.

> Filing GitHub issues from Error Tracking is a separate, opinionated workflow —
> use **`/et-sweep`** (the `fu-et-sweep` plugin) for that. Reach for `pup` here when
> you just want to **read/triage** Error Tracking, logs, or traces from the shell.

## Query & time syntax

- **Query strings** are standard Datadog search: `service:x status:error`,
  `@http.status_code:500`, wildcards `resource_name:"POST /orders/*"`, boolean
  `(a OR b) -c`. Attribute facets are prefixed `@`.
- **Time** (`--from` / `--to`): `1h`, `5min`, `2hours`, `'5 minutes'`, `7d`,
  RFC3339, a Unix timestamp, or `now`. `--from` defaults vary per command — pass it
  explicitly on anything time-series.

## Gotchas

- **Don't fetch raw logs to count them** — `logs aggregate --compute count`.
- **Don't open with `--limit 1000`** — start small (default 50), refine the query,
  widen only if needed. `--from 30d` is slow; use only when you truly need a month.
- **Read `.data`** from responses (agent-mode envelope), and `--no-agent` in any
  command you write into a script the user runs. But `--jq` filters the *payload*,
  not the envelope — root at `.[]` (logs/traces) or `.data[]` (error-tracking).
- **`error-tracking issues search` needs exactly one of `--track` / `--persona`** —
  not zero, not both.
- **APM = nanoseconds.** **401 → re-auth, 403 → missing scope** (see Auth).
- Deep/rare flags: `pup <domain> <cmd> --help` or `pup agent schema --compact`.

## Install / update

`pup` is a single static binary from GitHub releases (no package manager). Install
or update with the bundled script — re-run it to update:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/install-pup.sh        # [--dest DIR] to override location
```

It resolves the latest tag, picks this machine's asset (`uname`), verifies the
sha256, and installs over an existing `pup` on PATH (else `/usr/local/bin`; `sudo`
only when needed). OAuth session/config survive upgrades.
