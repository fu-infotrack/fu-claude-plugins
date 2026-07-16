# WSL setup: npm + NuGet private-feed auth (Azure Artifacts)

Date: 2026-07-16
Plugin: `fu-wsl-setup` (skill `wsl-setup`), Phase 12

## Problem

`fu-wsl-setup` Phase 12 already installs the Azure Artifacts Credential
Provider (`install-artifacts-credprovider.sh`), but that only drops the
binary — it's not wired to any feed, PAT, or config. Building a dotnet
project and a UI project against InfoTrack's private Azure Artifacts feeds
still surfaces auth failures on a freshly provisioned machine:

- **NuGet**: the credential provider is present but every restore against a
  private feed still needs an interactive login the first time — nothing in
  the skill documents or drives that.
- **npm/yarn**: nothing at all is covered. No `.npmrc`, no token, no
  registry auth. `@infotrack`-scoped installs (e.g. `@infotrack/zenith-ui`,
  registry `pkgs.dev.azure.com/InfoTrackAU` per the platform-frontend
  plugin's zenith-ui setup docs) 401 immediately.

Scope: **Azure Artifacts only** (not ProGet, which some older projects also
use — out of scope for this pass).

## Decisions

| Question | Decision | Why |
|---|---|---|
| Feed backend(s) | Azure Artifacts only | Matches the credential provider already installed; current standard for new projects. ProGet auth (different mechanism) deferred. |
| NuGet auth flow | Interactive-once (device-code), cached by the credential provider (~90 days) | No PAT to manage/rotate; matches the skill's existing real-terminal hand-off pattern (`az devops login`, `gh auth login`). |
| npm auth flow | PAT baked into `~/.npmrc` | `vsts-npm-auth` (Microsoft's normal interactive answer for npm) is Windows-only — no ADAL/browser-cache equivalent runs under WSL. PAT-in-`.npmrc` is the only reliable non-interactive path. |
| PAT entry mechanism | Real-terminal script, silent `read -s`, writes straight to `~/.npmrc` | Matches the repo's existing `fu-k8dash` token-capture pattern — the secret never appears in the Claude Code conversation/transcript. |
| Script vs inline | Bundle `scripts/npm-artifacts-auth.sh` | First script file in this plugin (currently 100% inline one-liners), but matches how other `fu-` plugins handle anything beyond a trivial one-liner (e.g. `fu-datadog-pup/scripts/install-pup.sh`). |

## Design

### NuGet (docs-only addition to Phase 12, no new script)

The credential provider is already installed. Add a subsection documenting:

1. A project's own `NuGet.config` must list the Azure Artifacts source
   (`https://pkgs.dev.azure.com/<org>/_packaging/<feed>/nuget/v3/index.json`)
   — that's project-level and already covered by platform-devsecops
   scaffolding; this skill doesn't duplicate it.
2. Plain `dotnet restore` is **non-interactive by design** — against an
   unauthenticated private feed it just fails 401, it does *not* prompt. The
   one-time hand-off is `dotnet restore --interactive` in a real terminal:
   only that flag lets the credential provider run its login. Under WSL
   there's no reliable GUI browser, so it uses the **device-code flow**:
   prints a URL + code; the user opens the URL in any browser (Windows host
   is fine) and enters the code. Same hand-off bucket as `az devops login` —
   Claude cannot drive it.
3. After that one-time login, the provider caches the token so subsequent
   *plain* (non-`--interactive`) restores succeed silently — including ones
   Claude runs.
4. Re-probe convention: after the hand-off, Claude re-runs a plain
   `dotnet restore` itself to confirm it now succeeds non-interactively.
5. Gotcha to document: when the cached token expires, plain restores start
   failing 401 against the feed again (in some MSBuild contexts they hang
   instead). Either symptom on a previously working machine = redo the
   `dotnet restore --interactive` hand-off.

### npm (`scripts/npm-artifacts-auth.sh`)

```
Usage: npm-artifacts-auth.sh <registry-url>
  e.g. npm-artifacts-auth.sh https://pkgs.dev.azure.com/InfoTrackAU/_packaging/<feed>/npm/registry/
```

The registry URL is a required argument, not hardcoded — per the skill's
existing "ask the user for the actual value" placeholder convention (feed
names vary; the zenith-ui setup docs note the registry URL "has varied over
time"). The script normalizes it to a trailing `/` — `.npmrc` credential
keys must end `…/:` to match, so a missing slash silently breaks auth.

Flow:

1. **Live-verify first** — `npm whoami --registry <url>`. Success → print
   "already authenticated" and exit 0. This replaces a presence-only probe
   (grep for an existing `_password` line): a presence-only check would
   report "already configured" even after a PAT expires or rotates, silently
   masking a broken setup. (Not `npm ping` — Azure Artifacts has
   historically 404'd its `/-/ping` endpoint. If `whoami` also proves
   unsupported at implementation time, fall back to fetching a known private
   package: `npm view @infotrack/zenith-ui version --registry <url>`.)
2. On verify failure (missing, expired, or wrong-scope PAT — any reason):
   silent-read the PAT — `read -s -p "Azure DevOps PAT (Packaging Read
   scope): " PAT` — never as a CLI arg, never echoed, and since it's read
   into a shell variable (not typed as a bare command), it doesn't land in
   bash history either. Strip trailing `\r`/whitespace (a paste from the
   Windows clipboard often carries a CR that corrupts the credential).
3. Base64-encode the PAT — via builtins/stdin (`printf '%s' "$PAT" |
   base64 -w0`) so the secret never appears in an external process's argv,
   and **`-w0` is required**: GNU base64 wraps at 76 chars by default and
   current Azure DevOps PATs are long enough to wrap, splitting the
   credential across lines and corrupting `.npmrc`.
   Then **rewrite** (remove any existing lines for the exact host+paths
   first, then append fresh) the auth lines in `~/.npmrc` — for **both**
   the `…/npm/registry/` path *and* its `…/npm/` parent, exactly as Azure
   DevOps' own "Connect to feed" `.npmrc` does (some npm operations hit the
   shorter path; auth on only the long one intermittently 401s):
   ```
   //<host>/<org>/_packaging/<feed>/npm/registry/:username=<org>
   //<host>/<org>/_packaging/<feed>/npm/registry/:_password=<base64-PAT>
   //<host>/<org>/_packaging/<feed>/npm/registry/:email=<placeholder>
   //<host>/<org>/_packaging/<feed>/npm/:username=<org>
   //<host>/<org>/_packaging/<feed>/npm/:_password=<base64-PAT>
   //<host>/<org>/_packaging/<feed>/npm/:email=<placeholder>
   always-auth=true
   ```
   Username: any non-empty value works for Azure Artifacts basic auth — use
   the org name parsed from the URL. Email: npmrc's legacy auth format
   requires some value but Azure Artifacts doesn't validate it — a
   placeholder is fine. `always-auth=true`: npm 9+ removed the option (it's
   an ignored unknown-config warning there) — kept anyway because **yarn v1**
   (which the skill pins) still honours it and needs it to send auth on some
   requests.
4. `chmod 600 ~/.npmrc` unconditionally (create the file first if missing).
5. Re-verify with the same `npm whoami --registry <url>` call, print a plain
   pass/fail.

Needs `npm` on `PATH` (Phase 5's fnm alias-bin). Since this script is
already a real-terminal hand-off (user opens a terminal to enter the PAT), a
fresh interactive shell sources `~/.bashrc` correctly — no extra PATH wiring
needed, just a one-line note so nobody tries to run it via a non-interactive
`bash -lc` and hits the missing-npm gotcha from Phase 5.

## Testing

- `bash -n scripts/npm-artifacts-auth.sh` — syntax check.
- Smoke test under a throwaway `$HOME` with `npm` stubbed on `PATH`
  (mirrors the `fu-mssql-stage` named-host smoke-test pattern already used
  in this repo) — verifies idempotent rewrite (no duplicate lines across
  repeated runs), both path variants written, single-line base64 (no wrap),
  and the `chmod 600` result, without needing a real PAT.
- Live end-to-end verification (both the NuGet device-code flow and the npm
  script against a real Azure Artifacts feed) cannot be exercised by Claude
  — no WSL GUI/AAD session available in this environment. **User-verified
  only**, the first time they actually build a project against InfoTrack's
  feeds.

## Out of scope

- ProGet auth (different mechanism — basic auth / API key against
  `proget.infotrack.com.au`).
- PAT auto-renewal/rotation.
- Per-project `NuGet.config`/`.npmrc` scope-to-registry mapping (that's
  project-level, already handled by platform scaffolding/existing project
  files).
