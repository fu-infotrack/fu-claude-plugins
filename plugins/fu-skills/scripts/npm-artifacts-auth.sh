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
[ -n "$ORG" ] || { echo "error: cannot parse org from registry URL" >&2; exit 2; }
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
trap 'rm -f "$TMP"' EXIT
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
