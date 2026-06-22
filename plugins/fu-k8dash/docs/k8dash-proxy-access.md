# fu-k8dash — read-only Kubernetes access via the k8dash proxy

**Status:** implemented and validated live against the stage cluster (2026-06-22).

## Problem

Inspect Kubernetes status on the **stage** cluster (pod health, deployments, events,
logs) to debug the many projects hosted there. The only access available is the web
dashboard at the configured `dashboardUrl` (set in fu-tools config; no host is baked
into the code) — there is no `kubectl`, no kubeconfig, no cluster credentials, and no
Azure access. Tooling must replay what the browser already does.

## Why this works (the mechanism)

The dashboard is Skooner (a k8dash fork):

- The server (`server/index.js`) is a **thin Express proxy** — `/` serves the React
  app, `/oidc` runs SSO, and **`/*` proxies straight to the apiserver** with no
  per-path business logic.
- The browser attaches `Authorization: Bearer <id_token>` (an OIDC JWT held in
  `localStorage.authToken`) to **every** API call (`client/src/services/apiProxy.ts`).
- The apiserver authenticates the token and applies **RBAC** — a caller gets exactly
  the user's own permissions; the proxy grants no escalation.

So holding that bearer token, we can `GET` the standard Kubernetes REST API through the
proxy and receive the same JSON the React app consumes. This is API access, not HTML
scraping.

## Decisions

- **Packaging:** a marketplace plugin (`fu-k8dash`), not a per-project skill — the
  stage cluster hosts many projects, so the tool is reusable. Matches the
  `fu-pg-stage` / `fu-mssql-stage` naming and the config-resolved-host pattern.
- **API, not scraping.** `raw <path>` is the **primary contract**: any standard
  apiserver path the user's RBAC permits. The named subcommands (`pods`, `deploy`,
  `logs`, …) are ergonomic sugar over standard paths.
- **Read-only / GET-only, enforced in the script.** The one network primitive
  (`k8get`) hard-codes the method to `GET`; no subcommand can issue a mutating verb,
  even with a cluster-admin token. (`SelfSubjectRulesReview` would enumerate
  permissions but is a `POST`, so it is deliberately not used — the RBAC boundary is
  observed via `403`s instead.)
- **Per-cluster, config-resolved host — explicit cluster selection.** Each cluster
  (stage, prod, …) has its own `k8dash.<cluster>.url` in fu-tools config and
  its own token file (`~/.claude/fu-tools/k8dash/clusters/<cluster>/token`), so they
  never collide. Pick one with a leading `-c <cluster>`; omitted → `defaultCluster`.
  **prod is never the default** — you reach it only by typing `-c prod`, and any
  prod-named cluster prints a ⚠ banner — so you can't hit prod by omission. There is no
  mutable "current-context" state (which could leave you unknowingly pointed at prod);
  selection is explicit per command. No host is baked into the source.
- **Token is file-resident and never enters the agent's context.** The value lives
  only in `~/.claude/fu-tools/k8dash/token` (0600) and the `curl` process — never in
  a chat message, an env var, a command-line argument, or any printed output. It is
  ingested by `k8dash login`, which writes the file and echoes nothing but
  seconds-of-validity. Three sources, none routing the value through the model:
  - `--browser` (preferred) — `scripts/k8dash-login` opens the dashboard in a real
    (headed) Chromium via `playwright-cli` and waits up to 10 min while the user
    authenticates **in the browser** (username / password / MFA typed into the window,
    never into the script or any agent context). It then reads `localStorage.authToken`
    (captured into a script-local var via `eval --raw`, never printed) plus the browser
    storage state / cookies (`browser-state.json`, 0600), writes them, and closes the
    browser. Self-contained: the only inputs are typed into the browser.
  - `--clip` — `copy(localStorage.authToken)` in devtools → OS clipboard → file.
  - stdin — paste into `login` on stdin.

  `K8DASH_TOKEN` (a raw token in the environment) is deliberately **not** supported,
  so the token can't ride in on a command line. The file is kept out of any repo and
  out of the wiped plugin cache; `whoami` decodes the JWT offline for an
  identity/expiry check. An agent runs the read-only queries and only the k8s
  *responses* return to it — never the token.
  - (Residual, out of scope for this constraint: the bearer header is in `curl`'s argv,
    visible to other local processes via `ps` — not to the agent. Harden later with a
    `curl -K` config on a pipe if that local exposure matters.)

## Out of scope (YAGNI)

Any write/mutation verb, `exec`, `port-forward`, `cp`; an MCP server; *automatic*
(unattended/headless) token refresh — `login --browser` is a **headed, human-driven**
login, deliberately so (it handles MFA and keeps credentials in the browser only);
multi-cluster *fan-out* (querying several clusters in one command — you select exactly
one cluster per invocation with `-c`); response caching.

The headed-login path also persists cookies (`browser-state.json`), which gives us a
session cookie on hand should Open Question 1 (an SSO/WAF wall in front of the proxy)
turn out to require one.

## Validated against stage (2026-06-22)

A live run via `login --browser` + read-only queries resolved every open question:

1. **SSO/WAF wall?** **No.** The bearer token alone returns JSON from every path
   tried — no HTML/`302` wall in front of the proxy, so no session cookie is needed.
   (The script still detects an HTML body and reports it, in case that ever changes.)
2. **Token TTL?** **~24h** (`exp` ≈ 86,400s out), not the presumed ~1h — so a login
   comfortably lasts a working day. `whoami` shows `seconds_left`.
3. **Namespace discovery?** Works — `ns` lists the cluster's namespaces (≈800 on
   stage) and `pods <ns>` confirms an app's pods; the app→namespace name usually
   matches.
4. **Full pass-through or whitelisted proxy?** **Full pass-through** — `raw /version`
   and arbitrary apiserver paths return real JSON. Cluster is EKS, k8s `v1.35.5`,
   `linux/arm64`. RBAC (the user's own) is the only limiter.

## Files

- `.claude-plugin/plugin.json` — manifest (skill).
- `scripts/fu-config.sh` — the shared fu-tools resolver (verbatim copy; keep aligned
  with the other plugins' copies).
- `scripts/k8dash` — the GET-only client; `${CLAUDE_PLUGIN_ROOT}/scripts/k8dash`.
- `scripts/k8dash-login` — the headed-browser OIDC login (also reachable as
  `k8dash login --browser`); drives `playwright-cli`, captures the token + cookies to
  disk without the token or any credential touching stdout/agent context.
- `skills/k8dash/SKILL.md` — proxy model, GET-only guarantee, token refresh recipe,
  subcommands, workflows.

## Testing

- **`whoami`** — offline decode of a sample JWT → claims + `exp`, no network.
- **GET-only guard** — there is no non-GET code path; verified by inspection (single
  `curl -X GET` primitive) and by the absence of mutating subcommands.
- **Live smoke (done 2026-06-22)** — `login --browser` captured a token; `ns` listed
  ~800 namespaces, `pods <ns>`/`deploy <ns>` returned items, `raw /version` returned
  apiserver JSON. See "Validated against stage" — all four open questions resolved.
