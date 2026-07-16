#!/usr/bin/env bash
# Smoke tests for npm-artifacts-auth.sh — sandboxed HOME, stubbed npm, no network, no real PAT.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/npm-artifacts-auth.sh"
URL="https://pkgs.dev.azure.com/InfoTrackAU/_packaging/MyFeed/npm/registry/"
KEY_LONG="//pkgs.dev.azure.com/InfoTrackAU/_packaging/MyFeed/npm/registry/"
KEY_SHORT="//pkgs.dev.azure.com/InfoTrackAU/_packaging/MyFeed/npm/"
FAILURES=0

SANDBOXES=()
trap 'rm -rf "${SANDBOXES[@]}"' EXIT

fail() { echo "FAIL $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "ok   $1"; }
check() { # check <name> <cmd...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

setup() { # fresh sandbox: throwaway HOME + stub npm on PATH
  SANDBOX=$(mktemp -d)
  SANDBOXES+=("$SANDBOX")
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
check "short-path username written" grep -qxF "${KEY_SHORT}:username=InfoTrackAU" "$HOME/.npmrc"
check "short-path email written" grep -q "^${KEY_SHORT}:email=" "$HOME/.npmrc"
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
OUT=$(NPM_WHOAMI_ALWAYS=ok bash "$SCRIPT" "$URL" </dev/null 2>&1)
check "already-authed exits 0" [ $? -eq 0 ]
check "already-authed prints contract line" grep -q "already authenticated" <<<"$OUT"
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
