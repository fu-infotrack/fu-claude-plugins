---
name: wsl-setup
description: Use when setting up a WSL work environment for Claude Code on a Windows machine — checks the WSL version, picks or creates a Debian instance, reports every tool's status (installed or missing), then drives the full tool install sequence from a Windows-host PowerShell 7+ session, running non-interactive probes itself and handing privileged/interactive steps to the user. Triggers — "set up wsl", "provision a wsl work environment for claude code", "new work machine setup", "wsl debian setup", "what's installed in my wsl".
---

# Set up a WSL work environment for Claude Code

## Before anything — environment guard

This skill orchestrates WSL from the **Windows host** and requires **PowerShell 7+**. Confirm both, and **stop** if either fails:

- Windows host (platform is `win32`).
- `pwsh` 7 or newer:

```powershell
$PSVersionTable.PSVersion   # Major must be >= 7
```

If not on Windows or PowerShell is < 7, stop and tell the user: this skill provisions WSL from a Windows-host PowerShell 7+ session and cannot run here.

## How this runbook works

Two command channels, chosen per step:

- **Claude runs (non-interactive):** version checks, `wsl -l -v`, per-tool presence probes (`wsl -d $DISTRO -u $USER -- bash -lc 'command -v gh'`), `--version` calls, connectivity `curl`s, and any install needing no human input. Claude may run privileged **system** steps directly as **`wsl -d $DISTRO -u root -- …`** — WSL grants root with **no password**, so this avoids `sudo` prompts entirely. (User-scoped writes to `~` must still run as `$USER`, never root, or they land root-owned in the home dir.)
- **User runs — two kinds:**
  - **`!` hand-off (in-session):** works only for **line-prompt** interaction — a `sudo` password, a `y/n`, pasting a token. Batch each phase's consecutive `sudo` commands into one `!` block.
  - **Real terminal window (NOT `!`):** anything that **spawns an interactive shell or a full-screen / arrow-key TUI** — first-launch UNIX user creation, `gh auth login`, `az devops login`, `vault login`. Claude's `!` has no full PTY and cannot drive these; tell the user to run them in a normal Windows Terminal / PowerShell window and report back.

  These real-terminal hand-offs are the **credential-entry** steps. Draw the line there: **credential-free configuration** — anything that only needs a value the user tells you (Azure DevOps org/project defaults, the Vault address, a repo to clone) — Claude sets directly once it has the value; **ask for those values up front and set them yourself**, don't hand them off. Only the secret/credential entry itself is a hand-off. After any hand-off, re-probe before advancing.

**Resumability:** no state file. Start every phase with its presence probe, so a re-run skips completed work. The Inventory step (below) gives the full installed/missing picture up front and lets the user opt out of tools they don't want.

**Naming:** once the instance is chosen, set two PowerShell variables and use them in every `wsl` call below — `$DISTRO` (the distro name) and `$USER` (its default Linux user, captured in Phase 1). Windows-host steps (VSCode, DevTunnel, sqlcmd) run in PowerShell, not inside WSL.

**Placeholders:** anything in `<angle-brackets>` — internal URLs, org / repo names, a Vault address, an LDAP username — is environment-specific. **Ask the user for the actual value** before running the command; never hard-code one.

**PATH caveat:** commands run via `wsl … -- bash -lc '…'` are **non-interactive**, so a stock Debian/Ubuntu `~/.bashrc` returns early at its interactivity guard and `source ~/.bashrc` loads nothing (and a login shell's `~/.profile` was already read at startup, before any installer edited it). So a tool whose installer only appends to those files (fnm, dotnet, aspire) is **not on `PATH` in the same command** — either set its env explicitly in that command, or run the follow-up in a freshly opened interactive WSL shell.

**Transport caveat:** the command transport blanks `$`-substitutions evaluated at runtime — `$(…)` command substitution, `. /etc/os-release`-sourced vars (`$ID`, `$VERSION_CODENAME`), `$(whoami)`, and any var assigned earlier in the same command. Only pre-existing environment vars (`$HOME`, `$USER`, `$PATH`) survive. So **do not derive values inline**: read the distro's `ID`/`VERSION_CODENAME`/arch once (the Phase 1 sanity probe), then **substitute the concrete values** into the apt-repo commands below (shown as `<id>` / `<codename>` / `<arch>` placeholders). This holds whether Claude runs the command or hands it off, and applies to installs (fnm's `eval "$(fnm env)"`, the Docker/Vault/gh repo lines) as much as to probes.

## Phase 0 — Windows preflight

Confirm the WSL version is recent enough (require **≥ 2.7.1**):

```powershell
wsl --version
```

If the WSL app is older, update it (may require elevation — hand off if it fails without admin):

```powershell
wsl --update
```

**Check disk headroom.** A WSL2 distro's `df /` reports its **virtual** disk max (~1 TB) and is misleading — the real limit is free space on the **Windows drive** backing the distro's `ext4.vhdx`, which the vhdx grows into. Provisioning the full toolset (dotnet SDK, chromium, docker, node, …) consumes roughly **5–6 GB**. Check the backing drive (a new instance installs under `%LOCALAPPDATA%` on `C:`; an existing one lives at its `HKCU:\…\Lxss\<guid>\BasePath` drive):

```powershell
Get-PSDrive C | ForEach-Object { 'C: free {0:N0} GB of {1:N0} GB' -f ($_.Free/1GB), (($_.Used+$_.Free)/1GB) }
```

If free space is under **~10 GB**, warn the user before installing — vhdx growth could fill the drive. Do **not** rely on `df /` inside the distro; it shows the sparse virtual max, not real headroom.

## Phase 1 — Pick or create the instance

List existing distros and their WSL versions:

```powershell
wsl -l -v
```

Show the list to the user and ask: provision an existing instance, or create a fresh one?

- **Create new** (default distro is Debian, matching this guide). Give it an explicit name with `--name` (so it never clashes with an existing `Debian`) and `--no-launch` to keep the install non-interactive — Claude can run this:

```powershell
wsl --install -d Debian --name <name> --no-launch
```

  (Older WSL without `--name`: a second same-named distro isn't possible — install `Debian` only if none exists, else `wsl --import <name> <dir> <tarball>`.)

  Then create the **UNIX user**. First-launch OOBE is a shell prompt `!` can't drive, so use one of:

  - **Claude-run (non-interactive):** create the user as root, add to `sudo`, set as default. This is a **passwordless** account (fine for a dev box — pair with `NOPASSWD` sudo below, or set a password later in a terminal):

```powershell
wsl -d <name> -u root -- bash -lc 'id <user> >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo <user>; echo "<user> ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-<user> && chmod 440 /etc/sudoers.d/90-<user>; grep -qF "[user]" /etc/wsl.conf 2>/dev/null || printf "[user]\ndefault=<user>\n" >> /etc/wsl.conf'
wsl --terminate <name>
```

  - **Real terminal:** the user opens a Windows Terminal window, runs `wsl -d <name>`, completes the username/password OOBE prompts, then `exit`.

- **Use existing:** the user names the distro to target.

Set the two PowerShell variables every later call uses — `$DISTRO` (the chosen distro) and `$USER` (its default Linux user):

```powershell
$DISTRO = '<distro-name>'
$USER   = (wsl -d $DISTRO -- bash -lc 'whoami').Trim()
```

**Distro sanity:** confirm it is Debian/Ubuntu (apt-based); if not, warn the user that the apt-based steps below assume Debian/Ubuntu. **Tested surface:** this runbook has only been exercised end-to-end on **Debian 13 (trixie)**. Ubuntu and other apt distros share the same structure and should work, but are **untested** — watch for repo-codename and package-name differences (and the Docker/HashiCorp `<codename>` you substitute).

```powershell
wsl -d $DISTRO -- bash -lc 'grep -E "^(ID|VERSION_CODENAME)=" /etc/os-release'
```

**Enable systemd** — Docker's service management (Phase 8) and the wsl-vpnkit auto-start unit (Phase 3) both need systemd running as PID 1. Probe it (Claude may run this):

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'systemctl is-system-running 2>/dev/null | grep -qE "running|degraded" && echo systemd-on || echo systemd-off'
```

If `systemd-off`, enable it (writes `/etc/wsl.conf`, so hand off the `sudo`):

```
! wsl -d $DISTRO -- bash -lc 'grep -q "systemd=true" /etc/wsl.conf 2>/dev/null || printf "[boot]\nsystemd=true\n" | sudo tee -a /etc/wsl.conf'
```

then restart WSL so it takes effect — this stops **all** distros, so reopen to continue (the `$DISTRO`/`$USER` PowerShell variables survive `wsl --shutdown`):

```powershell
wsl --shutdown
```

Re-probe after the restart and confirm `systemd-on` before advancing. (If `/etc/wsl.conf` already has a `[boot]` section, add `systemd=true` under it by hand instead — the append above would write a second `[boot]` stanza.)

## Inventory — tool status and selection

Before installing anything, probe every tool, show the user a status table, and let them choose what to install. Claude runs these probes — they are read-only.

**Inside the distro** — augment `PATH` with the locations this skill installs to (per the PATH caveat, `command -v` alone would report installed-but-rc-only tools as missing), then probe each tool. Iterate with **`xargs -I{}`**, not a `for` loop, and avoid sourced vars and `$(…)`: some harnesses expand `$` in the command string before the shell runs it, blanking any variable assigned at runtime (a `for` var, a sourced value) — but `xargs`'s `{}` placeholder carries no `$`, so it survives the pass and behaves identically when a human runs it. Only environment vars (`$HOME`, `$PATH`) are safe to reference. The tools with fallback locations are checked explicitly after the loop: node/yarn under `~/.local/share/fnm/aliases/default/bin`, dotnet under `~/.local/share/dotnet`. The yarn check **excludes a `/mnt/…` hit** — a Windows-node `yarn` on the interop PATH otherwise reads as a false positive. Per the Transport caveat, the apt-repo hand-offs below use **substituted** `<id>`/`<codename>`/`<arch>` values from the Phase 1 sanity probe, not inline `$(…)`/sourced vars.

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.local/share/fnm/aliases/default/bin:$HOME/.dotnetup:$HOME/.local/share/dotnet:$HOME/.aspire/bin:$PATH"; printf "%s\n" gh fnm az claude docker aspire vault psql chromium zsh | xargs -I{} sh -c "command -v {} >/dev/null 2>&1 && echo {} installed || echo {} missing"; { command -v node >/dev/null 2>&1 || [ -x "$HOME/.local/share/fnm/aliases/default/bin/node" ]; } && echo "node installed" || echo "node missing"; { [ -x "$HOME/.local/share/fnm/aliases/default/bin/yarn" ] || command -v yarn 2>/dev/null | grep -qv "^/mnt/"; } && echo "yarn installed" || echo "yarn missing"; { command -v dotnet >/dev/null 2>&1 || [ -x "$HOME/.local/share/dotnet/dotnet" ] || command -v dotnetup >/dev/null 2>&1; } && echo "dotnet installed" || echo "dotnet missing"'
```

**On the Windows host** — the three host-installed tools:

```powershell
foreach ($t in 'code','devtunnel','sqlcmd') {
  if (Get-Command $t -ErrorAction SilentlyContinue) { "$t`tinstalled" } else { "$t`tmissing" }
}
```

Present the combined result as a table mapping each tool to its phase, e.g.:

| Tool | Phase | Where | Status |
|------|-------|-------|--------|
| gh | 4 | distro | installed |
| fnm / node / yarn | 5 | distro | missing |
| claude | 6 | distro | missing |
| code (VSCode) | 7 | Windows host | installed |
| docker | 8 | distro | missing |
| chromium | 9 | distro | missing |
| dotnet | 10 | distro | missing |
| aspire | 11 | distro | missing |
| az (Azure DevOps) | 12 | distro | missing |
| devtunnel | 13 | Windows host | missing |
| vault | 14 | distro | missing |
| psql (postgresql-client) | 15 | distro | installed |
| sqlcmd | 16 | Windows host | missing |
| zsh (optional) | — | distro | missing |

Then **ask the user which of the missing tools to install** — they can opt out of any they don't need (e.g. Docker, dotnet, Aspire, Azure DevOps, DevTunnel, Vault; zsh is opt-in already). Install only tools that are **both missing and not opted out**, running the phases below in order. Skip every phase whose tool is already installed or was opted out, and tell the user which phases you skipped and why.

Treat the Phase 5 row (`fnm` / `node` / `yarn`) as installed only if all three probe lines report installed. Phases 2 (base update) and 3 (connectivity gate) have no tool of their own and always run.

## Phase 2 — Base update

Update, then install the base tooling later phases assume — the minimal Debian image ships **without `curl`/`wget`/`gnupg`**, and Phase 3's connectivity check needs `curl`. Claude can run this via `-u root`, or hand off:

```
! wsl -d $DISTRO -- bash -lc 'sudo apt update && sudo apt upgrade -y && sudo apt install -y curl wget gnupg ca-certificates unzip'
```

## Phase 3 — Connectivity gate (Netskope cert + VPN)

Add the Netskope CA cert (batched `sudo` hand-off):

```
! wsl -d $DISTRO -- bash -lc 'sudo ln -sf /mnt/c/ProgramData/NetskopeCACerts/netskope-cacert.pem /usr/local/share/ca-certificates/netskope.crt && sudo update-ca-certificates && echo "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt" | sudo tee -a /etc/environment'
```

Add the Node CA export to `~/.bashrc` (no sudo; Claude may run this):

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'grep -q NODE_EXTRA_CA_CERTS ~/.bashrc || echo "export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt" >> ~/.bashrc'
```

A **corporate VPN** (e.g. wsl-vpnkit — see https://github.com/sakai135/wsl-vpnkit) is required to reach internal resources and is set up separately.

**Detect an existing wsl-vpnkit first** (read-only; Claude may run these) — it installs one of three ways, and each leaves a different fingerprint. Don't offer to install it if any of these hit:

```powershell
wsl -l -v   # a distro literally named "wsl-vpnkit" = the distro-import install (the repo's recommended way)
wsl -d $DISTRO -- bash -lc 'systemctl list-unit-files --no-legend 2>/dev/null | grep -i vpnkit; command -v wsl-vpnkit; ls /usr/local/bin/wsl-vpnkit 2>/dev/null'
```

- **Distro import:** `wsl-vpnkit` appears in `wsl -l -v`. Auto-start is usually a **systemd unit inside `$DISTRO`** (`/etc/systemd/system/wsl-vpnkit.service`, `enabled`) whose `ExecStart` runs `wsl.exe -d wsl-vpnkit …` — check `systemctl list-unit-files | grep vpnkit`, since it lives in your work distro, not the vpnkit distro. Running distros each get their own isolated systemd (own PID 1), so a systemd-enabled vpnkit distro alongside a systemd-enabled work distro is expected, not a conflict.
- **Standalone script:** `command -v wsl-vpnkit` resolves or `/usr/local/bin/wsl-vpnkit` exists inside `$DISTRO`, with a `wsl-gvproxy.exe` on the Windows side.
- Either way, a running instance shows as a `gvproxy`/`wsl-vpnkit` process (`ps aux | grep -Ei 'gvproxy|vpnkit'`).

If none of these hit and internal resources are needed, install it — **distro import is the preferred method** (self-contained: the vpnkit engine lives in its own distro, nothing scattered inside the work distro).

**Preflight — networking mode.** wsl-vpnkit requires WSL's **default (NAT)** networking and does **not** work under `mirrored` mode. Check the Windows-host `%USERPROFILE%\.wslconfig` (no file = NAT default, which is correct):

```powershell
$wc = "$env:USERPROFILE\.wslconfig"; if (Test-Path $wc) { Select-String -Path $wc -Pattern networkingMode } else { 'no .wslconfig - NAT default (good)' }
```

If it sets `networkingMode=mirrored`, switch it to `NAT` (or delete the line) and run `wsl --shutdown` before continuing.

On the **Windows host**, download the latest release tarball and import it as its own distro:

```powershell
$tar = "$env:TEMP\wsl-vpnkit.tar.gz"
Invoke-WebRequest -Uri https://github.com/sakai135/wsl-vpnkit/releases/latest/download/wsl-vpnkit.tar.gz -OutFile $tar
wsl --import wsl-vpnkit "$env:USERPROFILE\wsl-vpnkit" $tar --version 2
Remove-Item $tar
```

Auto-start it from `$DISTRO` via a systemd unit — this is why Phase 1 enables systemd. The unit launches the vpnkit distro at boot and restarts it if it drops; writing it needs `sudo` (Claude can also run it via `-u root`), so hand off:

```
! wsl -d $DISTRO -- bash -lc 'printf "%s\n" "[Unit]" "Description=wsl-vpnkit" "After=network.target" "" "[Service]" "ExecStart=/mnt/c/Windows/system32/wsl.exe -d wsl-vpnkit --cd /app wsl-vpnkit" "Restart=always" "KillMode=mixed" "" "[Install]" "WantedBy=multi-user.target" | sudo tee /etc/systemd/system/wsl-vpnkit.service && sudo systemctl daemon-reload && sudo systemctl enable --now wsl-vpnkit.service'
```

**Multi-distro caveat.** All distros share **one** VM network, and the `wsl-vpnkit` distro is shared. So if **another work distro already runs the wsl-vpnkit service**, its tunnel already covers this distro too — do **not** start a second instance: two services both running `wsl -d wsl-vpnkit` fight over the same named pipe (`Restart=always` then fail-loops). In that case install and `enable` the unit (so it's wired for when this becomes the distro that runs vpnkit) but drop `--now` — use `sudo systemctl enable wsl-vpnkit.service`. Only one distro runs vpnkit at a time.

Confirm the unit came up (skip if you deliberately left it stopped per the caveat), then verify an internal resource is now reachable (ask the user for an `<internal-url>` to test):

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'systemctl is-active wsl-vpnkit.service; curl -sSfL -o /dev/null <internal-url> && echo internal-ok'
```

Note: the auto-start unit lives in **`$DISTRO`**, not the imported `wsl-vpnkit` distro — it just shells out to `wsl.exe -d wsl-vpnkit`. The two distros each run their own isolated systemd (own PID 1); a systemd-enabled vpnkit distro alongside a systemd-enabled work distro is expected, not a conflict.

Validate public connectivity now:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'curl -sSfL -o /dev/null https://www.google.com && echo public-ok'
```

Internal resources (e.g. the Vault server in Phase 14) additionally need the VPN up. Validate that reachability at the phase that needs it, asking the user for an internal URL to test — do not gate the public-internet phases below on it.

## Phase 4 — GitHub CLI

Probe:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'command -v gh'
```

If missing, install it (substitute `<arch>` — e.g. `amd64` — per the Transport caveat; `$(mktemp)`/`$(dpkg …)` would blank). Claude can run this via `-u root`, or hand off:

```
! wsl -d $DISTRO -- bash -lc 'sudo mkdir -p -m 755 /etc/apt/keyrings && sudo wget -nv -O /etc/apt/keyrings/githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && sudo mkdir -p -m 755 /etc/apt/sources.list.d && echo "deb [arch=<arch> signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null && sudo apt update && sudo apt install gh -y'
```

Authenticate — `gh auth login` is an arrow-key TUI, so the user runs it in a **real terminal** window (not `!`): `wsl -d $DISTRO`, then `gh auth login`, then `exit`.

Optionally clone a repo — ask the user which `<owner>/<repo>` they need:

```
! wsl -d $DISTRO -- bash -lc 'gh repo clone <owner>/<repo>'
```

## Phase 5 — fnm / Node / yarn

Probe:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'command -v fnm && command -v node'
```

Install the apt prerequisites — `curl`/`unzip` (from Phase 2) plus **`libatomic1`**, which the fnm-built Node needs at runtime (minimal Debian omits it; without it `node` dies with `libatomic.so.1: cannot open shared object file`). Claude can run via `-u root`, or hand off:

```
! wsl -d $DISTRO -- bash -lc 'sudo apt install -y curl unzip libatomic1'
```

Then install fnm, Node, and yarn. **`eval "$(fnm env)"` cannot be used here** — the transport blanks `$(…)`, so node never activates (Transport caveat). Instead call fnm by **absolute path** (only `$HOME`/`$PATH` survive) and prepend the fnm default-alias bin to `PATH` so `npm`'s `#!/usr/bin/env node` shebang resolves. **Yarn stays v1 (classic, 1.22.x)** — `npm install -g yarn` installs the 1.x line, which legacy code depends on; do **not** enable Corepack or move to Yarn Berry (v2+). No sudo — Claude may run this:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'curl -o- https://fnm.vercel.app/install | bash -s -- --install-dir "$HOME/.local/share/fnm" && "$HOME/.local/share/fnm/fnm" install 26 && "$HOME/.local/share/fnm/fnm" default 26 && export PATH="$HOME/.local/share/fnm/aliases/default/bin:$PATH" && node -v && npm -v && npm install -g yarn && yarn --version'
```

Then **persist the default-alias bin on `PATH`.** The fnm installer adds an `eval "$(fnm env)"` block to `~/.bashrc`, but **that alone does not put `node` on `PATH`** in a fresh shell — it sets fnm up without activating the default version, so `node` goes missing and a Windows `/mnt/c` `yarn` wins the PATH. Adding the alias bin fixes both. **Escape `\$`** so the literal `$HOME`/`$PATH` are written — an *unescaped* `$PATH` inside double quotes bakes a frozen snapshot of the current PATH instead of re-expanding at each shell start:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'grep -q fnm/aliases/default/bin ~/.bashrc || echo "export PATH=\"\$HOME/.local/share/fnm/aliases/default/bin:\$PATH\"" >> ~/.bashrc'
```

Verify `yarn --version` reports **1.22.x** and that `command -v yarn` resolves inside `~/.local/share/fnm`, not `/mnt/c/...` (a Windows-node yarn leaking via PATH interop).

## Phase 6 — Claude Code CLI

Probe:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'command -v claude'
```

Install (no sudo; Claude may run this). Escape `\$` in the persisted PATH line so the literal `$HOME`/`$PATH` are written, not a frozen snapshot:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'curl -fsSL https://claude.ai/install.sh | bash && (grep -q ".local/bin" ~/.bashrc || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc)'
```

## Phase 7 — VSCode (Windows host)

Install VSCode on the **Windows host** if missing:

```powershell
winget install --id Microsoft.VisualStudioCode -e
```

Tell the user to install the **WSL extension** (`ms-vscode-remote.remote-wsl`) in VSCode, then trigger the VS Code Server install from inside the distro:

```
! wsl -d $DISTRO -- bash -lc 'cd ~ && code .'
```

## Phase 8 — Docker

Probe:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'command -v docker'
```

Install. Substitute `<id>` (`debian`/`ubuntu`), `<codename>` (e.g. `trixie`), `<arch>` (e.g. `amd64`) from the Phase 1 sanity probe, and `<user>` — the sourced `$ID`/`$VERSION_CODENAME` and `$(whoami)`/`$(dpkg …)` would blank (Transport caveat). Docker publishes per-release repos (trixie included); if a very new release 404s, fall back to the previous codename. Claude can run via `-u root` (drop `sudo`), or hand off:

```
! wsl -d $DISTRO -- bash -lc 'sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/<id>/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && printf "Types: deb\nURIs: https://download.docker.com/linux/<id>\nSuites: <codename>\nComponents: stable\nArchitectures: <arch>\nSigned-By: /etc/apt/keyrings/docker.asc\n" | sudo tee /etc/apt/sources.list.d/docker.sources && sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && sudo usermod -aG docker <user> && sudo systemctl enable --now docker'
```

Note: the `docker` group membership needs a new login shell (`newgrp docker` or reopen WSL) to take effect. Verify the service:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'systemctl is-active docker'
```

## Phase 9 — Chromium

```
! wsl -d $DISTRO -- bash -lc 'sudo apt install -y chromium'
```

## Phase 10 — dotnet

Probe:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'command -v dotnet || command -v dotnetup'
```

Install the `dotnetup` bootstrapper, then run the SDK install **by absolute path** — no interactive shell needed (the old `! wsl -d $DISTRO` hand-off can't be driven by `!`). `dotnetup` lands in `~/.dotnetup`; the SDK installs to `~/.local/share/dotnet` (**not** `~/.dotnet`). No sudo — Claude may run this:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'curl -fsSL https://aka.ms/dotnetup/get-dotnetup.sh | bash && "$HOME/.dotnetup/dotnetup" install latest && "$HOME/.local/share/dotnet/dotnet" --version'
```

Persist both dirs on `PATH` for future shells. Guard on the **Linux** SDK path (`local/share/dotnet`), not `.dotnetup` — a frozen Windows PATH snapshot can contain `/mnt/c/.../.dotnetup`, which would false-match and skip this. Escape `\$` so the literal `$HOME`/`$PATH` are written:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'grep -q "local/share/dotnet" ~/.bashrc || echo "export PATH=\"\$HOME/.dotnetup:\$HOME/.local/share/dotnet:\$PATH\"" >> ~/.bashrc'
```

## Phase 11 — Aspire CLI

The installer drops the CLI at `~/.aspire/bin/aspire` and adds it to `~/.bashrc` itself. No sudo — Claude may run this, verifying by absolute path (sidesteps the PATH caveat):

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'curl -sSL https://aspire.dev/install.sh | bash && "$HOME/.aspire/bin/aspire" --version'
```

## Phase 12 — Azure DevOps

Install the Artifacts credential provider (no sudo; Claude may run it):

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'wget -qO- https://aka.ms/install-artifacts-credprovider.sh | bash'
```

Then Azure CLI — the `InstallAzureCLIDeb` script adds Microsoft's apt repo (it falls back to the `bookworm` package on newer Debian, which is fine). Claude can run via `-u root`, or hand off:

```
! wsl -d $DISTRO -- bash -lc 'curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash'
```

Add the extension (Claude may run it):

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'az extension add --name azure-devops'
```

Then set the org/project defaults, which need **no credentials** — ask the user for their Azure DevOps **organization URL** (`<org-url>`, e.g. `https://dev.azure.com/<org>`) and default **project** (`<project>`), then Claude runs it:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'az devops configure --defaults organization=<org-url> project=<project>'
```

Only `az devops login` needs credentials (PAT / browser), so the user runs it in a **real terminal** (`wsl -d $DISTRO`, then the command, then `exit`):

```
az devops login --organization <org-url>
```

## Phase 13 — DevTunnel (Windows host)

Install on the **Windows host** (shared across all WSL instances); once on PATH it is reachable from WSL as `devtunnel`:

```powershell
winget install Microsoft.devtunnel
```

## Phase 14 — Hashicorp Vault

Probe:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'command -v vault'
```

Install. Substitute `<codename>`/`<arch>` per the Transport caveat (sourced `$VERSION_CODENAME` and `$(dpkg …)` blank). Claude can run via `-u root`, or hand off:

```
! wsl -d $DISTRO -- bash -lc 'wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && echo "deb [arch=<arch> signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com <codename> main" | sudo tee /etc/apt/sources.list.d/hashicorp.list && sudo apt update && sudo apt install -y vault'
```

**Ask the user for their Vault URL.** They may paste a **browser UI URL** (e.g. `https://<host>/ui/vault/secrets/...`) — but `VAULT_ADDR` is only the **scheme + host (+ port)**, so derive it rather than trusting the pasted string verbatim:

```powershell
# <vault-url> = whatever the user pasted; keep only scheme://host[:port]
$vaultAddr = ([uri]'<vault-url>').GetLeftPart([System.UriPartials]::Authority)
$vaultAddr   # confirm with the user; this is <vault-addr> below
```

(e.g. `https://example-vault.internal/ui/vault/secrets` → `https://example-vault.internal`.) Also ask for their **LDAP username** (`<ldap-username>`).

Vault is an **internal** resource, so ensure the corporate VPN is up first and test reachability against the derived `<vault-addr>`. Persist `VAULT_ADDR` for future interactive shells (no sudo):

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'grep -q VAULT_ADDR ~/.bashrc || echo "export VAULT_ADDR=\"<vault-addr>\"" >> ~/.bashrc'
```

Then log in — `vault login -method=ldap` prompts for a password, so the user runs it in a **real terminal** (pass `VAULT_ADDR` inline, since a non-interactive shell won't have sourced `~/.bashrc`): `wsl -d $DISTRO`, then

```
VAULT_ADDR="<vault-addr>" vault login -method=ldap username=<ldap-username>
```

## Phase 15 — postgresql-client

```
! wsl -d $DISTRO -- bash -lc 'sudo apt install -y postgresql-client'
```

## Phase 16 — sqlcmd (Windows host)

sqlcmd runs on the **Windows host** (it supports Windows Authentication, which WSL cannot use). Check first — it may already be installed and reachable from WSL as `sqlcmd.exe`:

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'sqlcmd.exe --version'
```

If not found, install it on the Windows host:

```powershell
winget install --id Microsoft.Sqlcmd -e
```

Then it is usable from WSL as `sqlcmd.exe -S <server> -d <database>`.

## Optional — zsh

Ask the user once whether they want zsh (the guide marks it optional; default skip). If yes — set the shell with **`sudo chsh`**, substituting `<user>`: a plain `chsh` authenticates the *user's* password and **fails on the passwordless account** Phase 1 can create (`chsh: PAM: Authentication failure`); `sudo chsh -s /usr/bin/zsh <user>` needs no user password. The literal `/usr/bin/zsh` (confirmed present in `/etc/shells`) avoids `$(which zsh)`, which the transport blanks. Claude can run via `-u root`, or hand off:

```
! wsl -d $DISTRO -- bash -lc 'sudo apt install -y zsh zsh-autosuggestions zsh-syntax-highlighting && sudo chsh -s /usr/bin/zsh <user>'
```

```powershell
wsl -d $DISTRO -u $USER -- bash -lc 'echo "source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh" >> ~/.zshrc; echo "source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> ~/.zshrc'
```

**Migrate the env into `~/.zshrc`.** A zsh login does **not** read `~/.bashrc`, so without this zsh has no node/dotnet/vault/PATH. Add the lines this guide put in `~/.bashrc`, with two zsh adjustments: use `eval "$(fnm env --shell zsh)"` (not `--shell bash`), and keep the **alias-bin PATH prepend** from Phase 5 (fnm env alone won't activate node). The block:

```sh
export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
export VAULT_ADDR="<vault-addr>"
export PATH="$HOME/.local/bin:$HOME/.dotnetup:$HOME/.local/share/dotnet:$HOME/.aspire/bin:$HOME/.local/share/fnm/aliases/default/bin:$PATH"
if [ -d "$HOME/.local/share/fnm" ]; then export PATH="$HOME/.local/share/fnm:$PATH"; eval "$(fnm env --shell zsh)"; fi
```

This text is `$`-heavy, so write it from an **interactive WSL shell** (or the user's terminal) where `$`/heredocs behave normally — a `bash -lc` one-liner risks the transport blanking `$(fnm env)`/`$PATH`. If you write it from the Windows host (e.g. piping a here-string to `tee`), ensure **LF** line endings — a stray `\r` makes zsh fail with `parse error near \n` (`sed -i 's/\r$//' ~/.zshrc` fixes it). Verify:

```powershell
wsl -d $DISTRO -- zsh -ic 'true'                                  # no parse error
wsl -d $DISTRO -- zsh -ic 'command -v node; command -v yarn'      # both under ~/.local/share/fnm, not /mnt/c
```

Because Claude Code reads `$SHELL`, override it to bash just for Claude by adding to `~/.claude/settings.json`:

```json
{ "env": { "SHELL": "/bin/bash" } }
```

Starship (optional prompt) — **ask first, default skip**, same as zsh; don't install it unless the user says yes (a passing mention or question is not a yes). If yes: the bare install script **prompts for confirmation** (hangs non-interactively) and installs to `/usr/local/bin`, so pass `-y` and run as root — `curl -sS https://starship.rs/install.sh | sh -s -- -y` (Claude via `-u root`, or hand off). Then add `eval "$(starship init zsh)"` to the **end** of `~/.zshrc` — write it with **LF** and a literal `$(...)` (same caveat as the env block above; append via stdin/`tee` then `sed -i 's/\r$//'` if needed).

## When something fails

After each hand-off, re-run that phase's probe/verify. If it still fails, report the exact command and output to the user and offer to retry or inspect — do not advance to the next phase on a failed verify.
