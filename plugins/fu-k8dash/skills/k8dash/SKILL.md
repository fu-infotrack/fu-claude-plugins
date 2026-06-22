---
name: k8dash
description: Use when inspecting Kubernetes status on a stage or prod cluster — pod health, deployments, events, logs, nodes, resource usage. Read-only, GET-only, via the k8dash dashboard's API proxy using the user's OIDC bearer token; pick the cluster with -c (default stage; prod requires an explicit -c prod). Use when a k8s lookup is needed but there is no kubectl/kubeconfig, or when the token returns 401.
---

# Inspecting Kubernetes via the k8dash proxy

There is no `kubectl`, no kubeconfig, and no cluster credentials here — only a web
dashboard per cluster (the configured `dashboardUrl`; set per cluster, no default).
That dashboard (Skooner / k8dash) is a **thin pass-through proxy**: the browser
attaches `Authorization: Bearer <id_token>` to every call and the proxy forwards it
straight to the Kubernetes apiserver. We replay exactly that — so this tool's reach is
**exactly the user's own RBAC**, nothing more.

**Pick a cluster with `-c <cluster>` before the subcommand** (e.g. `-c prod`); omitted
→ `defaultCluster` (stage). prod is never the default — you reach it only explicitly,
and it prints a ⚠ banner. Each cluster has its own URL and its own token file.

Drive it through the bundled wrapper — never hand-roll the curl:

```bash
K8=${CLAUDE_PLUGIN_ROOT}/scripts/k8dash
"$K8" whoami                # default cluster: who the token is + expiry (offline)
"$K8" ns                    # default cluster: namespaces you can see
"$K8" -c prod pods <ns>     # PROD: pod health in a namespace
"$K8" -c prod raw <path>    # PROD: GET any apiserver path (the primary contract)
```

## Read-only / GET-only guarantee

The single network primitive hard-codes the HTTP method to `GET`. No subcommand can
issue POST/PUT/PATCH/DELETE — there is no mutating code path, even if the token is
cluster-admin. `exec`, `port-forward`, `cp`, and scaling are intentionally absent.

## Config (fu-tools) — per cluster

Resolved via `${CLAUDE_PLUGIN_ROOT}/scripts/fu-config.sh k8dash <key>`; no host is
hardcoded — each cluster's URL is set in config.

| key | meaning |
|---|---|
| `defaultCluster` | cluster used when `-c` is omitted (e.g. `stage`) |
| `<cluster>.url` | that cluster's k8dash host — **required per cluster** |

```jsonc
"k8dash": {
  "defaultCluster": "stage",
  "stage": { "url": "https://stage-k8dash…" },
  "prod":  { "url": "https://prod-k8dash…" }
}
```

Each cluster's token lives at `~/.claude/fu-tools/k8dash/clusters/<cluster>/token`
(`0600`) — stage and prod never collide. Env overrides: `K8DASH_CLUSTER`,
`K8DASH_DASHBOARD_URL`, `K8DASH_TOKEN_PATH`. The raw token is **never** taken from an
env var or a command-line argument — only from the per-cluster file (see Token).

## Token — never leaves the local file

The token is the OIDC `id_token` the dashboard keeps in `localStorage.authToken`
(short-lived). **It must never be pasted into a chat/agent, an env var, or a command
line** — it lives only in the token file and the `curl` process. `login` gets it
there and never echoes it. Three sources:

**Preferred — `login --browser` (headed OIDC login), per cluster:**

```bash
k8dash -c stage login --browser   # opens that cluster's dashboard in a real Chromium window
k8dash -c prod  login --browser   # prod: separate login, separate token file
```

It waits up to 10 min while **you** log in in that window (username / password /
MFA — all typed into the browser, never into this script or any agent context),
then captures `localStorage.authToken` (and cookies, to `browser-state.json`) to the
token file and closes the browser. No devtools, no clipboard. Needs a display
(WSLg/X on WSL) and `playwright-cli`. `--timeout <s>` / `--keep-open` available.

**Alternatives — clipboard or stdin:**

```bash
# in the dashboard devtools CONSOLE (token → clipboard, not your screen):
copy(localStorage.authToken)
k8dash -c <cluster> login --clip   # clipboard → that cluster's token file (or: login, paste on stdin)
```

Any source writes the cluster's token file `0600` and confirms only seconds-of-validity
— not the token, not your identity. The file lives under `~/.claude` (a user dir),
never in a repo or the wiped plugin cache. **Refresh on 401:** re-run `login` for that
cluster. `whoami` shows `seconds_left` to check before a run.

Because the token is file-resident, an agent can drive the read-only queries (`ns`,
`pods`, …) and only the k8s **responses** enter its context — the token never does.
This is the whole point: `copy(localStorage.authToken)` → clipboard → file → `curl`,
with no step that routes the value through the model.

## Subcommands

Every command takes an optional leading `-c <cluster>` (before the subcommand); without
it the `defaultCluster` is used.

| command | apiserver path | shows |
|---|---|---|
| `login [--browser\|--clip]` | — (writes the token file) | get a token in: `--browser` headed OIDC login, `--clip` clipboard, else stdin; never echoes it |
| `whoami` | — (offline JWT decode) | subject, groups, `exp`, seconds left |
| `ns` | `/api/v1/namespaces` | namespace + phase |
| `pods [ns]` | `/api/v1/namespaces/<ns>/pods` (or all) | phase, ready, restarts, node |
| `deploy [ns]` | `/apis/apps/v1/.../deployments` | ready / up-to-date / available |
| `events [ns]` | `/api/v1/namespaces/<ns>/events` | recent events, oldest→newest |
| `logs <ns> <pod> [container]` | `/api/v1/.../pods/<pod>/log` | last 200 lines, timestamped |
| `nodes` | `/api/v1/nodes` | ready, kubelet version, OS image |
| `top-pods [ns]` / `top-nodes` | `metrics.k8s.io/v1beta1/...` | CPU/memory (if metrics API present) |
| `raw <path>` | the path you give | pretty-printed JSON — **use for anything not above** |

The named subcommands are ergonomic sugar; `raw` is the real contract — any standard
Kubernetes REST path your RBAC permits.

## Workflows

- **Find a project's namespace:** `k8dash ns`, then `k8dash pods <ns>` to confirm
  (a service's namespace usually matches its app name). The app/namespace mapping is
  not in `k8_settings` — discover it here.
- **Triage a sick service:** `pods <ns>` → spot non-`Running`/high-restart pods →
  `logs <ns> <pod>` for the crash → `events <ns>` for scheduling/image errors.
- **Capacity:** `nodes` for readiness; `top-pods <ns>` / `top-nodes` for usage.

## Gotchas

- **HTML instead of JSON** → an SSO/WAF wall sits in front of the proxy and the bearer
  token alone is not enough (a session cookie would be needed). The wrapper detects and
  reports this rather than printing garbage.
- **403** → your RBAC does not allow that path. Expected for some namespaces/resources;
  not a bug. `whoami` shows your groups.
- **`top-*` unavailable** → `metrics.k8s.io` is not installed/readable on the cluster.
- Logs are tail-limited (200 lines) by design; widen with
  `raw "/api/v1/namespaces/<ns>/pods/<pod>/log?tailLines=2000&timestamps=true"`.
