# wsl-setup npm + NuGet Azure Artifacts auth — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the private-feed auth gap in `fu-wsl-setup` Phase 12 so a dotnet project and an npm/yarn project both build against InfoTrack's private Azure Artifacts feeds on a freshly provisioned WSL machine.

**Architecture:** Two independent additions to Phase 12 of `plugins/fu-wsl-setup/skills/wsl-setup/SKILL.md`. NuGet is docs-only (the credential provider is already installed; document the one-time `dotnet restore --interactive` device-code hand-off). npm gets a new bundled script `scripts/npm-artifacts-auth.sh` that the *user* runs in a real terminal — it live-verifies with `npm whoami`, silently prompts for a PAT only when needed, and rewrites `~/.npmrc` (dual-path entries, base64 `-w0`, `chmod 600`). Spec: `docs/superpowers/specs/2026-07-16-wsl-npm-nuget-artifacts-auth-design.md` (read it before starting any task).

**Tech Stack:** bash (script + self-contained smoke-test script, no framework), Markdown (SKILL.md), JSON (plugin manifest).

**Branch/landing context:** Work happens in the worktree on branch `wsl-auth-impl` (based on `origin/feat/wsl-artifacts-auth-spec`, PR #2). Each task commits normally; the orchestrator squashes all task commits into ONE implementation commit and pushes to `feat/wsl-artifacts-auth-spec` at the end. Do not push from inside a task.

## Global Constraints

- The PAT is a secret: never a CLI argument, never echoed, never written to the conversation — `read -s` from the terminal only.
- `base64 -w0` always (GNU base64 wraps at 76 chars; a wrapped credential corrupts `.npmrc`).
- `.npmrc` credential keys must end in `/` before the `:` — normalize the registry URL to a trailing slash.
- Write auth lines for **both** `…/npm/registry/` and its parent `…/npm/` path (matches Azure DevOps' generated "Connect to feed" `.npmrc`).
- Shell scripts must be LF-only (they execute inside WSL; a CRLF checkout on a Windows host would break the shebang) — enforced via `.gitattributes`.
- Verify with `npm whoami --registry <url>`, never `npm ping` (Azure Artifacts historically 404s `/-/ping`).
- `always-auth=true` is written once — npm 9+ ignores it (unknown-config warning); it stays solely for yarn v1, which the skill pins.
- Repo conventions: no new dependencies beyond `bash`/`npm`-on-PATH; plugin cache only picks up changed bundled files after a version bump + uninstall + install.

---

### Task 1: `npm-artifacts-auth.sh` + smoke tests + `.gitattributes`

**Files:**
- Create: `.gitattributes` (repo root)
- Create: `plugins/fu-wsl-setup/scripts/npm-artifacts-auth.sh`
- Test: `plugins/fu-wsl-setup/scripts/npm-artifacts-auth.test.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `npm-artifacts-auth.sh <registry-url>` — exit 0 = authenticated (either already, or after writing `~/.npmrc`); exit 1 = auth failed/empty PAT; exit 2 = usage error. Task 2's SKILL.md text references this script by its path and behavior (prints `already authenticated` on the no-op path).

- [ ] **Step 1: Create `.gitattributes`**

Write repo-root `.gitattributes` with exactly:

```
*.sh text eol=lf
```

- [ ] **Step 2: Write the failing smoke-test script**

Create `plugins/fu-wsl-setup/scripts/npm-artifacts-auth.test.sh`:

```bash
#!/usr/bin/env bash
# Smoke tests for npm-artifacts-auth.sh — sandboxed HOME, stubbed npm, no network, no real PAT.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/npm-artifacts-auth.sh"
URL="https://pkgs.dev.azure.com/InfoTrackAU/_packaging/MyFeed/npm/registry/"
KEY_LONG="//pkgs.dev.azure.com/InfoTrackAU/_packaging/MyFeed/npm/registry/"
KEY_SHORT="//pkgs.dev.azure.com/InfoTrackAU/_packaging/MyFeed/npm/"
FAILURES=0

fail() { echo "FAIL $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "ok   $1"; }
check() { # check <name> <cmd...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

setup() { # fresh sandbox: throwaway HOME + stub npm on PATH
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$SANDBOX/bin"
  export NPM_STATE="$SANDBOX/whoami-called"
  # Stub npm: first `npm whoami` fails (unauthenticated), later calls succeed
  # (post-write verify). NPM_WHOAMI_ALWAYS=ok makes every call succeed.
  cat > "$SANDBOX/bin/npm" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "whoami" ]; then
  [ "${NPM_WHOAMI_ALWAYS:-}" = "ok" ] && exit 0
  [ -f "$NPM_STATE" ] && exit 0
  touch "$NPM_STATE"
  exit 1
fi
exit 0
STUB
  chmod +x "$SANDBOX/bin/npm"
  export PATH="$SANDBOX/bin:$PATH"
}

# --- 1. fresh run writes both key paths, single-line base64, 600 perms ---
setup
printf 'testpat\n' | bash "$SCRIPT" "$URL" >/dev/null 2>&1
check "fresh run exits 0" [ $? -eq 0 ]
EXPECTED_B64=$(printf '%s' 'testpat' | base64 -w0)
check "long-path _password written"  grep -qxF "${KEY_LONG}:_password=${EXPECTED_B64}" "$HOME/.npmrc"
check "short-path _password written" grep -qxF "${KEY_SHORT}:_password=${EXPECTED_B64}" "$HOME/.npmrc"
check "username is org"              grep -qxF "${KEY_LONG}:username=InfoTrackAU" "$HOME/.npmrc"
check "always-auth written once"     [ "$(grep -cx 'always-auth=true' "$HOME/.npmrc")" = "1" ]
check "npmrc is 0600"                [ "$(stat -c %a "$HOME/.npmrc")" = "600" ]

# --- 2. re-run is an idempotent rewrite (no duplicate lines) ---
LINES_BEFORE=$(wc -l < "$HOME/.npmrc")
rm -f "$NPM_STATE"   # make the first whoami fail again, forcing a rewrite
printf 'testpat\n' | bash "$SCRIPT" "$URL" >/dev/null 2>&1
check "re-run exits 0" [ $? -eq 0 ]
check "re-run adds no lines" [ "$(wc -l < "$HOME/.npmrc")" = "$LINES_BEFORE" ]
check "still exactly 2 _password lines" [ "$(grep -c ':_password=' "$HOME/.npmrc")" = "2" ]

# --- 3. CR from a Windows-clipboard paste is stripped ---
setup
printf 'testpat\r\n' | bash "$SCRIPT" "$URL" >/dev/null 2>&1
check "CR stripped (same base64)" grep -qxF "${KEY_LONG}:_password=${EXPECTED_B64}" "$HOME/.npmrc"

# --- 4. missing trailing slash is normalized ---
setup
printf 'testpat\n' | bash "$SCRIPT" "${URL%/}" >/dev/null 2>&1
check "trailing slash normalized" grep -qxF "${KEY_LONG}:_password=${EXPECTED_B64}" "$HOME/.npmrc"

# --- 5. already authenticated: exit 0, .npmrc untouched ---
setup
NPM_WHOAMI_ALWAYS=ok bash "$SCRIPT" "$URL" </dev/null >/dev/null 2>&1
check "already-authed exits 0" [ $? -eq 0 ]
check "already-authed writes no .npmrc" [ ! -f "$HOME/.npmrc" ]

# --- 6. usage errors ---
setup
bash "$SCRIPT" </dev/null >/dev/null 2>&1
check "no-arg exits 2" [ $? -eq 2 ]
bash "$SCRIPT" "http://insecure.example/npm/registry/" </dev/null >/dev/null 2>&1
check "non-https exits 2" [ $? -eq 2 ]

echo
if [ "$FAILURES" -gt 0 ]; then echo "$FAILURES failure(s)"; exit 1; fi
echo "all tests passed"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash plugins/fu-wsl-setup/scripts/npm-artifacts-auth.test.sh`
Expected: FAIL lines (the script under test does not exist yet), non-zero exit.

- [ ] **Step 4: Write the implementation**

Create `plugins/fu-wsl-setup/scripts/npm-artifacts-auth.sh`:

```bash
#!/usr/bin/env bash
# Register an Azure DevOps PAT for an Azure Artifacts npm registry in ~/.npmrc.
# The PAT is read silently from the terminal — never a CLI arg, never echoed.
# Run this interactively (needs npm on PATH, which an interactive shell provides).
set -euo pipefail
umask 077

usage() {
  echo "Usage: $(basename "$0") <registry-url>" >&2
  echo "  e.g. $(basename "$0") https://pkgs.dev.azure.com/InfoTrackAU/_packaging/<feed>/npm/registry/" >&2
  exit 2
}

[ $# -eq 1 ] || usage
REGISTRY="$1"
case "$REGISTRY" in
  https://*) ;;
  *) echo "error: registry URL must start with https://" >&2; usage ;;
esac
# .npmrc credential keys must end in '/' before the ':' or they never match.
# (case, not `[ … ] && …` — a false && list would trip set -e)
case "$REGISTRY" in
  */) ;;
  *) REGISTRY="$REGISTRY/" ;;
esac

# Live verify, not a presence grep: a presence check would report "configured"
# even after the PAT expires or rotates. (whoami, not ping — Azure Artifacts
# has historically 404'd /-/ping.)
if npm whoami --registry "$REGISTRY" >/dev/null 2>&1; then
  echo "already authenticated to $REGISTRY"
  exit 0
fi

read -r -s -p "Azure DevOps PAT (Packaging Read scope): " PAT
echo
PAT="${PAT//$'\r'/}"          # a Windows-clipboard paste often carries a CR
PAT="${PAT//[$'\t\n ']/}"     # and stray whitespace
[ -n "$PAT" ] || { echo "error: empty PAT" >&2; exit 1; }

# printf is a builtin and base64 reads stdin, so the PAT never appears in any
# process's argv. -w0 is required: GNU base64 wraps at 76 chars by default and
# current PATs are long enough to wrap, splitting the credential across lines.
B64=$(printf '%s' "$PAT" | base64 -w0)
unset PAT

KEY="${REGISTRY#https:}"                  # //host/org/_packaging/feed/npm/registry/
ORG=$(printf '%s' "$KEY" | cut -d/ -f4)   # first path segment after //host/
KEYS=("$KEY")
# Azure DevOps' own "Connect to feed" .npmrc also auths the parent .../npm/
# path — some npm operations hit it; auth on only the long path intermittently 401s.
case "$KEY" in
  */npm/registry/) KEYS+=("${KEY%registry/}") ;;
esac

NPMRC="$HOME/.npmrc"
touch "$NPMRC"
chmod 600 "$NPMRC"

# Rewrite, don't append: drop any existing lines for these keys (and the
# always-auth flag), then add fresh ones.
TMP=$(mktemp)
awk -v k1="${KEYS[0]}:" -v k2="${KEYS[1]:+${KEYS[1]}:}" '
  index($0, k1) == 1 { next }
  k2 != "" && index($0, k2) == 1 { next }
  $0 == "always-auth=true" { next }
  { print }
' "$NPMRC" > "$TMP"

{
  cat "$TMP"
  for k in "${KEYS[@]}"; do
    printf '%s:username=%s\n' "$k" "$ORG"
    printf '%s:_password=%s\n' "$k" "$B64"
    printf '%s:email=%s\n' "$k" "npm requires email to be set but does not use the value"
  done
  echo 'always-auth=true'
} > "$NPMRC"
rm -f "$TMP"
chmod 600 "$NPMRC"

if npm whoami --registry "$REGISTRY" >/dev/null 2>&1; then
  echo "OK: authenticated to $REGISTRY"
else
  echo "FAIL: npm whoami still failing against $REGISTRY" >&2
  echo "  - check the PAT has Packaging (Read) scope and covers this org" >&2
  echo "  - some feeds do not implement whoami; sanity-check with:" >&2
  echo "    npm view @infotrack/zenith-ui version --registry $REGISTRY" >&2
  exit 1
fi
```

Note the `k2` guard: `${KEYS[1]:+${KEYS[1]}:}` passes `"<short-key>:"` when the second path exists and `""` otherwise, and the awk `k2 != "" &&` guard skips the empty case — a bare `index($0, "") == 1` is always true and would strip every line.

Then make both files executable:

```bash
chmod +x plugins/fu-wsl-setup/scripts/npm-artifacts-auth.sh plugins/fu-wsl-setup/scripts/npm-artifacts-auth.test.sh
```

- [ ] **Step 5: Syntax check + run the tests to verify they pass**

Run: `bash -n plugins/fu-wsl-setup/scripts/npm-artifacts-auth.sh && bash plugins/fu-wsl-setup/scripts/npm-artifacts-auth.test.sh`
Expected: `all tests passed`, exit 0. If any `FAIL` line prints, fix the implementation (not the test) unless the test contradicts the spec.

- [ ] **Step 6: Commit**

```bash
git add .gitattributes plugins/fu-wsl-setup/scripts/npm-artifacts-auth.sh plugins/fu-wsl-setup/scripts/npm-artifacts-auth.test.sh
git commit -m "feat(fu-wsl-setup): npm Azure Artifacts PAT auth script"
```

---

### Task 2: SKILL.md Phase 12 — private-feed auth docs

**Files:**
- Modify: `plugins/fu-wsl-setup/skills/wsl-setup/SKILL.md` (insert after the `az devops login --organization <org-url>` code block that ends Phase 12, immediately before the `## Phase 13 — DevTunnel (Windows host)` heading)

**Interfaces:**
- Consumes: `scripts/npm-artifacts-auth.sh` from Task 1 (path, arg, `already authenticated` no-op behavior, exit codes).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Insert the two subsections**

Insert this text into `SKILL.md` between the `az devops login` block and `## Phase 13`:

````markdown
### Private-feed auth — NuGet (interactive once)

The credential provider installed above is only a binary — nothing is wired to a
feed yet. A project's own `NuGet.config` must list the Azure Artifacts source
(`https://pkgs.dev.azure.com/<org>/_packaging/<feed>/nuget/v3/index.json`); that
is project-level (platform scaffolding provides it), not this skill's job.

Plain `dotnet restore` is **non-interactive by design** — against a private feed
with no cached token it fails 401; it never prompts. The one-time hand-off is a
**real terminal**, inside any repo that uses the feed (`wsl -d $DISTRO`, `cd`
into the repo, then):

```
dotnet restore --interactive
```

`--interactive` lets the credential provider run its **device-code flow**: it
prints a URL + code; open the URL in any browser (the Windows host's is fine)
and enter the code. The provider caches the token, so subsequent *plain*
restores — including ones Claude runs — succeed silently. After the hand-off,
Claude re-probes by running a plain `dotnet restore` itself.

**Expiry gotcha:** when the cached token expires, plain restores start failing
401 again (in some MSBuild contexts they hang instead). Either symptom on a
previously working machine → redo the `dotnet restore --interactive` hand-off.

### Private-feed auth — npm (PAT, scripted)

`vsts-npm-auth` is Windows-only, so under WSL the Azure Artifacts npm feed needs
a PAT baked into `~/.npmrc`. The bundled `scripts/npm-artifacts-auth.sh` does
it: live-verifies with `npm whoami`, silently prompts for a PAT (Packaging Read
scope) only when needed, and rewrites the `~/.npmrc` entries (both the
`…/npm/registry/` and parent `…/npm/` paths, base64 no-wrap, `chmod 600`).

Ask the user for the actual `<registry-url>`
(e.g. `https://pkgs.dev.azure.com/<org>/_packaging/<feed>/npm/registry/`) —
feeds vary across projects. Probe first (Claude runs; note the explicit fnm
PATH prepend per the PATH caveat):

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'export PATH="$HOME/.local/share/fnm/aliases/default/bin:$PATH"; npm whoami --registry <registry-url> >/dev/null 2>&1 && echo npm feed auth ok || echo npm feed auth missing'
```

If missing, the PAT entry is a **real-terminal hand-off** (it is a credential).
The plugin cache lives on the Windows host, so give the user the script's path
translated to the WSL view (`C:\Users\<u>\…` → `/mnt/c/Users/<u>/…` — derive it
from this skill's own install path) and have them run, in `wsl -d $DISTRO`:

```
bash /mnt/c/Users/<user>/.claude/plugins/cache/fu-claude-plugins/fu-wsl-setup/<version>/scripts/npm-artifacts-auth.sh <registry-url>
```

The script needs `npm` on `PATH`, which the user's fresh interactive shell
provides (Phase 5) — do **not** run it via a non-interactive `bash -lc`.
Re-probe after the hand-off with the same probe above; a re-run of the script
is also safe (it prints `already authenticated` and exits 0).
````

- [ ] **Step 2: Verify the insert**

Run: `grep -n "Private-feed auth" plugins/fu-wsl-setup/skills/wsl-setup/SKILL.md && awk '/### Private-feed auth — npm/,/## Phase 13/' plugins/fu-wsl-setup/skills/wsl-setup/SKILL.md | head -5`
Expected: two heading hits between Phase 12 and Phase 13; the npm subsection sits directly before `## Phase 13 — DevTunnel (Windows host)`.

- [ ] **Step 3: Commit**

```bash
git add plugins/fu-wsl-setup/skills/wsl-setup/SKILL.md
git commit -m "docs(fu-wsl-setup): Phase 12 private-feed auth for NuGet and npm"
```

---

### Task 3: Version bump + reinstall into the plugin cache

**Files:**
- Modify: `plugins/fu-wsl-setup/.claude-plugin/plugin.json` (line 3: `"version": "0.2.0"` → `"version": "0.3.0"`)

**Interfaces:**
- Consumes: Tasks 1–2 committed in the worktree.
- Produces: the installed cache at `~/.claude/plugins/cache/fu-claude-plugins/fu-wsl-setup/0.3.0/` containing the new script (what a live session actually loads).

- [ ] **Step 1: Bump the version**

In `plugins/fu-wsl-setup/.claude-plugin/plugin.json` change:

```json
  "version": "0.2.0",
```

to:

```json
  "version": "0.3.0",
```

- [ ] **Step 2: Validate the manifest**

Run: `claude plugin validate plugins/fu-wsl-setup`
Expected: validation success, no errors.

- [ ] **Step 3: Commit**

```bash
git add plugins/fu-wsl-setup/.claude-plugin/plugin.json
git commit -m "chore(fu-wsl-setup): bump to 0.3.0"
```

- [ ] **Step 4: Note the deferred reinstall (do NOT run it here)**

The marketplace indexes the repo's **main working tree**, and this work sits on an unmerged branch in a worktree — so `claude plugin marketplace update` + reinstall would just repackage 0.2.0 without these changes. The reinstall is deliberately deferred: the **orchestrator runs it after the PR merges to main**:

```bash
claude plugin marketplace update fu-claude-plugins
claude plugin uninstall fu-wsl-setup@fu-claude-plugins
claude plugin install fu-wsl-setup@fu-claude-plugins
ls ~/.claude/plugins/cache/fu-claude-plugins/fu-wsl-setup/0.3.0/scripts/npm-artifacts-auth.sh
```

(`install` no-ops on an unchanged version, hence the uninstall first. The final `ls` printing the script path is the success signal.) Your task ends at Step 3's commit — just state in your report that the cache reinstall is deferred to post-merge.

---

## Landing (orchestrator, not a subagent task)

After all tasks pass review: squash the task commits into one implementation commit and push to the PR branch. From the worktree:

```bash
git reset --soft origin/feat/wsl-artifacts-auth-spec
git commit -m "feat(fu-wsl-setup): npm + NuGet Azure Artifacts private-feed auth (v0.3.0)"
git push origin HEAD:feat/wsl-artifacts-auth-spec
```

PR #2 then carries exactly two commits: the spec and the implementation. The user merges. **After the merge lands on main**, the orchestrator runs the deferred cache reinstall from Task 3 Step 4 and confirms `.../fu-wsl-setup/0.3.0/scripts/npm-artifacts-auth.sh` exists. Live end-to-end (device-code NuGet login, real PAT against a real feed) is user-verified only, per the spec.
