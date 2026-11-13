#!/usr/bin/env bash
# Per-tool TLS check through an SSL-inspecting proxy (Netskope) inside WSL.
# Each installed tool makes one real HTTPS request to a public host; the result
# is PASS, FAIL-TLS (certificate not trusted — the thing this checks), FAIL
# (some other error: auth, network, …) or SKIP (tool not installed).
# Read-only: no installs, no config writes. Docker pulls one tiny image.
#
#   bash wsl-cert-check.sh          # run in an interactive WSL shell
#   bash wsl-cert-check.sh -q       # only print non-PASS lines
#
# Run it under the environment the tools really get. From the Windows host,
# compare `wsl -- bash -ic 'bash …'` (interactive: ~/.bashrc loaded) with
# `wsl -- bash -c 'bash …'` (non-interactive: what a bare wsl.exe launch sees).
set -u

QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1

# Prepend the user-scope install dirs the fu-wsl skill uses, so a tool that is
# installed but only on PATH via ~/.bashrc is still found (and tested).
export PATH="$HOME/.local/bin:$HOME/.local/share/fnm/aliases/default/bin:$HOME/.dotnetup:$HOME/.local/share/dotnet:$HOME/.aspire/bin:$HOME/.bun/bin:$PATH"

URL=https://pypi.org/simple/six/
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TLS_RE='certificate|x509|CERT_|self[- ]signed|unable to get local issuer|SSL|tls:'
fails=0

have() { command -v "$1" >/dev/null 2>&1; }

# check <label> <binary-or-path> <command...>
check() {
  local label=$1 bin=$2; shift 2
  if ! have "$bin" && [ ! -x "$bin" ]; then
    [ "$QUIET" = 1 ] || printf '%-14s SKIP     (not installed)\n' "$label"
    return
  fi
  local out rc
  out=$(timeout 60 "$@" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    [ "$QUIET" = 1 ] || printf '%-14s PASS\n' "$label"
  elif printf '%s' "$out" | grep -qiE "$TLS_RE"; then
    fails=$((fails+1))
    printf '%-14s FAIL-TLS %s\n' "$label" "$(printf '%s' "$out" | grep -iE -m1 "$TLS_RE" | cut -c1-140)"
  else
    fails=$((fails+1))
    printf '%-14s FAIL     rc=%s %s\n' "$label" "$rc" "$(printf '%s' "$out" | tail -n1 | cut -c1-140)"
  fi
}

echo "CA env: NODE_EXTRA_CA_CERTS=${NODE_EXTRA_CA_CERTS:-<unset>} SSL_CERT_FILE=${SSL_CERT_FILE:-<unset>} REQUESTS_CA_BUNDLE=${REQUESTS_CA_BUNDLE:-<unset>}"
issuer=$(echo | timeout 15 openssl s_client -connect pypi.org:443 -servername pypi.org 2>/dev/null | sed -n 's/^issuer=//p')
echo "pypi.org issuer: ${issuer:-<no handshake>}"
echo

check curl     curl     curl -sSf -o /dev/null "$URL"
check wget     wget     wget -q -O /dev/null "$URL"
check openssl  openssl  sh -c "echo | openssl s_client -connect pypi.org:443 -servername pypi.org -verify_return_error >/dev/null 2>&1"
check git      git      git ls-remote https://github.com/git/git HEAD
check gh       gh       gh api /zen
check python3  python3  python3 -c "import urllib.request as u; u.urlopen('$URL', timeout=30)"
check pip      python3  python3 -m pip download six --no-deps --no-cache-dir -q -d "$TMP/pip"
check uv       uv       sh -c "echo six | uv pip compile - -q --no-cache --python-preference only-system"
check node     node     node -e "fetch('$URL').then(r=>process.exit(r.ok?0:1),e=>{console.error(e.cause||e);process.exit(1)})"
check npm      npm      npm view six version --registry https://registry.npmjs.org/ --prefer-online
check yarn     yarn     yarn info left-pad version --registry https://registry.yarnpkg.com
check bun      bun      bun -e "const r=await fetch('$URL'); process.exit(r.ok?0:1)"
check dotnet   dotnet   dotnet package search Newtonsoft.Json --take 1 --source https://api.nuget.org/v3/index.json
check az       az       az extension list-available -o none
check docker   docker   docker pull -q hello-world
check vault    vault    sh -c "VAULT_ADDR=https://releases.hashicorp.com vault status 2>&1 | grep -qiE '$TLS_RE' && { vault status; exit 1; } || exit 0"
check chromium chromium sh -c "timeout 40 chromium --headless=new --no-sandbox --disable-gpu --dump-dom https://www.google.com 2>/dev/null | grep -q '<title>Google</title>' || { echo 'chromium: ERR_CERT / page did not load (check ~/.pki/nssdb)'; exit 1; }"

echo
if [ $fails -eq 0 ]; then echo "all installed tools trust the proxy CA"; else echo "$fails tool(s) failed"; fi
exit $((fails > 0))
