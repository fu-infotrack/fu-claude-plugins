#!/usr/bin/env bash
# Install or update the `pup` Datadog CLI from GitHub releases.
# pup is a single static binary (no package manager) — re-run this to update.
#
# Dest precedence: $1 / --dest DIR  >  dir of an existing `pup` on PATH  >  /usr/local/bin
# (defaulting to an existing pup's dir avoids a PATH split between two copies).
# Uses sudo only when the dest dir isn't writable.
#
# Requires: curl, jq, tar (sha256sum optional — used for an integrity check).
set -euo pipefail

REPO="DataDog/pup"
die()  { echo "install-pup: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || die "curl not found on PATH"
have jq   || die "jq not found on PATH"
have tar  || die "tar not found on PATH"

# Resolve install dir.
dest=""
case "${1:-}" in
  --dest)   dest="${2:?--dest needs a DIR}" ;;
  --dest=*) dest="${1#*=}" ;;
  "")       ;;
  *)        dest="$1" ;;
esac
if [ -z "$dest" ]; then
  if existing=$(command -v pup 2>/dev/null); then dest=$(dirname "$existing"); else dest="/usr/local/bin"; fi
fi

# Map this machine to a release asset (assets use arm64, not aarch64).
os=$(uname -s); arch=$(uname -m); [ "$arch" = aarch64 ] && arch=arm64

tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | jq -r '.tag_name // empty')
[ -n "$tag" ] || die "could not resolve the latest release tag (rate-limited or offline?)"
ver="${tag#v}"
asset="pup_${ver}_${os}_${arch}.tar.gz"
base="https://github.com/$REPO/releases/download/$tag"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "install-pup: downloading $asset ($tag)…" >&2
curl -fsSL "$base/$asset" -o "$tmp/$asset" || die "download failed: $base/$asset"

# Integrity: verify sha256 against the release checksums (best-effort — skipped if unavailable).
if curl -fsSL "$base/pup_${ver}_checksums.txt" -o "$tmp/sums.txt" 2>/dev/null && have sha256sum; then
  ( cd "$tmp" && grep " ${asset}\$" sums.txt | sha256sum -c - ) >/dev/null 2>&1 \
    || die "checksum mismatch for $asset — refusing to install"
  echo "install-pup: checksum OK" >&2
fi

tar -xzf "$tmp/$asset" -C "$tmp"
[ -f "$tmp/pup" ] || die "no 'pup' binary inside $asset"

mkdir -p "$dest" 2>/dev/null || true
if [ -w "$dest" ]; then
  install -m 0755 "$tmp/pup" "$dest/pup"
else
  echo "install-pup: $dest not writable — using sudo" >&2
  sudo install -m 0755 "$tmp/pup" "$dest/pup"
fi

echo "install-pup: installed -> $dest/pup" >&2
"$dest/pup" version
