#!/usr/bin/env bash
# Build a SQL Server connection from Vault's database secrets engine, starting from
# the database config: read it for the connection_url AND the roles it allows, pick
# a role, mint dynamic short-lived credentials, then assemble a connection.
#
# Minted creds are cached (see "Credential cache" below) and reused until they
# near lease expiry, so repeated calls don't mint a fresh login every time.
#
# Usage:
#   connect.sh [db-config] [role] [--sqlcmd|--export] [--mount <name>] [--fresh] [--purge]
#
#   [db-config]  Database config name (the path read is <mount>/config/<db-config>).
#                Optional: falls back to the resolved mssql-stage.dbConfig fu-tools value.
#   [role]       Role to generate creds from. Optional: falls back to mssql-stage.role,
#                else if the config allows exactly one role it is used automatically;
#                if it allows several and none is resolved, the roles are listed and we stop.
#   --sqlcmd     exec sqlcmd with the dynamic creds (needs sqlcmd installed).
#   --export     print `export SQLCMD*` lines to eval in your shell.
#   --mount      database secrets engine mount path (default: database / mssql-stage.mount).
#   --fresh      ignore any cached credential, mint a new one (and refresh the cache).
#   --purge      delete all cached mssql-stage credentials, then exit.
#
# Examples:
#   connect.sh                          # db-config + role from fu-tools config
#   connect.sh <db-config>              # auto-role, print ADO.NET connection string
#   connect.sh <db-config> <role>       # explicit role
#   connect.sh <db-config> --sqlcmd     # open a shell
#   eval "$(connect.sh <db-config> --export)"   # load SQLCMD* into shell
#
# Requires: vault (authenticated, VAULT_ADDR set), jq. sqlcmd for --sqlcmd.
set -euo pipefail

command -v vault >/dev/null || { echo "vault CLI not found" >&2; exit 1; }
command -v jq    >/dev/null || { echo "jq not found" >&2; exit 1; }

# fu-tools config resolver (sibling plugin script); empty if unavailable.
cfg() { "$(dirname "$0")/../../scripts/fu-config.sh" mssql-stage "$1" 2>/dev/null || true; }

# VAULT_ADDR: honour the environment, else resolve from config. Must be EXPORTED
# so the `vault` child process sees it (otherwise it falls back to 127.0.0.1:8200).
VAULT_ADDR="${VAULT_ADDR:-$(cfg vaultAddr)}"
: "${VAULT_ADDR:?VAULT_ADDR not set — set it or configure mssql-stage.vaultAddr, then \`vault login\`}"
export VAULT_ADDR

mount=""
mode=""
db=""
role=""
fresh=0
purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sqlcmd|--export) mode="$1" ;;
    --fresh) fresh=1 ;;
    --purge) purge=1 ;;
    --mount) mount="$2"; shift ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) if [ -z "$db" ]; then db="$1"; elif [ -z "$role" ]; then role="$1"; else echo "unexpected arg: $1" >&2; exit 2; fi ;;
  esac
  shift
done

# Fall back to config for unset values.
[ -n "$db" ]    || db="$(cfg dbConfig)"
[ -n "$role" ]  || role="$(cfg role)"
[ -n "$mount" ] || mount="$(cfg mount)"
[ -n "$mount" ] || mount="database"

# percent-decode: Vault's mssql plugin stores the connection_url URL-encoded
# (e.g. "User%20Id=%7B%7Busername%7D%7D"). No-op when there is nothing to decode.
urldec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }

# Extract an ADO.NET connection-string value by key (case-insensitive, trims spaces).
ado_get() {
  local want=${1,,} s=$2 kv k v
  local IFS=';'
  for kv in $s; do
    [ -z "$kv" ] && continue
    k=${kv%%=*}; v=${kv#*=}
    k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ "${k,,}" = "$want" ] && { printf '%s' "$v"; return 0; }
  done
  return 0   # key absent: print nothing, succeed (do not trip `set -e` in `x=$(ado_get …)`)
}

# ── Credential cache ─────────────────────────────────────────────────────────
# Reuse a minted credential across invocations until it nears lease expiry,
# instead of minting a fresh dynamic login every call. The cache holds the
# connection_url template plus the dynamic user/password — i.e. a SECRET — so it
# lives in a user-only (0600) file under the fu-tools cache dir, never the repo.
# Bounded by the lease: once a cred is within $cache_margin of expiry it is
# re-minted. Use --fresh to force a new mint, --purge to wipe the cache.
cache_dir="$HOME/.claude/fu-tools/cache/mssql-stage"
cache_margin=600   # re-mint when fewer than this many seconds of lease remain

if [ "$purge" = 1 ]; then
  rm -f "$cache_dir"/*.json 2>/dev/null || true
  echo "purged cached mssql-stage credentials in $cache_dir" >&2
  exit 0
fi

# Cache key: one file per (vault, mount, db, role) target.
cache_key() { printf '%s|%s|%s|%s' "$VAULT_ADDR" "$mount" "$1" "$2" | sha1sum | cut -c1-32; }

# Echo a cache file's JSON iff it exists and has > margin seconds of life left.
read_cache() {
  local f=$1 now exp
  [ -f "$f" ] || return 1
  exp=$(jq -r '.expiry // 0' "$f" 2>/dev/null) || return 1
  now=$(date +%s)
  [ "$exp" -gt "$((now + cache_margin))" ] 2>/dev/null || return 1
  cat "$f"
}

# Atomically write a 0600 cache file.
write_cache() {
  local f=$1 u=$2 n=$3 p=$4 r=$5 e=$6 tmp
  mkdir -p "$cache_dir"; chmod 700 "$cache_dir" 2>/dev/null || true
  tmp=$(mktemp "$cache_dir/.tmp.XXXXXX")
  jq -n --arg u "$u" --arg n "$n" --arg p "$p" --arg r "$r" --argjson e "$e" \
     '{urltmpl:$u, user:$n, pass:$p, role:$r, expiry:$e}' > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$f"
}

use_cache_json() {   # populate url/user/pass/expiry from a cache JSON blob
  url=$(jq -r '.urltmpl' <<<"$1"); user=$(jq -r '.user' <<<"$1")
  pass=$(jq -r '.pass' <<<"$1"); expiry=$(jq -r '.expiry' <<<"$1"); from_cache=1
}

url=""; user=""; pass=""; expiry=0; from_cache=0

# Phase 1: if the role is already known (arg/config), try the cache before any
# Vault call — a hit skips BOTH the config read and the creds mint.
if [ "$fresh" != 1 ] && [ -n "$db" ] && [ -n "$role" ]; then
  c=$(read_cache "$cache_dir/$(cache_key "$db" "$role").json") && use_cache_json "$c" || true
fi

if [ "$from_cache" != 1 ]; then
  [ -n "$db" ] || { echo "no db-config given and mssql-stage.dbConfig not configured" >&2; exit 2; }

  # 1. config: connection_url + the roles this DB allows.
  config_json=$(vault read -format=json "$mount/config/$db")
  raw_url=$(jq -r '.data.connection_details.connection_url // empty' <<<"$config_json")
  [ -n "$raw_url" ] || { echo "no connection_url in $mount/config/$db" >&2; exit 1; }
  url=$(urldec "$raw_url")

  # 2. resolve role from allowed_roles unless the caller named one.
  if [ -z "$role" ]; then
    mapfile -t roles < <(jq -r '.data.allowed_roles[]? // empty' <<<"$config_json")
    case ${#roles[@]} in
      0) echo "$mount/config/$db allows no roles — pass a role explicitly" >&2; exit 1 ;;
      1) role="${roles[0]}" ;;
      *) echo "$mount/config/$db allows multiple roles — pick one:" >&2
         printf '  %s\n' "${roles[@]}" >&2; exit 1 ;;
    esac
    # role was unknown at phase 1 — re-check the cache now that we have it.
    if [ "$fresh" != 1 ]; then
      c=$(read_cache "$cache_dir/$(cache_key "$db" "$role").json") && use_cache_json "$c" || true
    fi
  fi

  # 3. mint dynamic creds (only if still not satisfied from cache).
  if [ "$from_cache" != 1 ]; then
    creds_json=$(vault read -format=json "$mount/creds/$role")
    user=$(jq -r '.data.username' <<<"$creds_json")
    pass=$(jq -r '.data.password' <<<"$creds_json")
    lease=$(jq -r '.lease_duration' <<<"$creds_json")
    expiry=$(( $(date +%s) + lease ))
    write_cache "$cache_dir/$(cache_key "$db" "$role").json" "$url" "$user" "$pass" "$role" "$expiry"
  fi
fi

remaining=$(( expiry - $(date +%s) )); [ "$remaining" -lt 0 ] && remaining=0
src="minted"; [ "$from_cache" = 1 ] && src="cached"

# 4. Parse the ADO.NET connection_url. SQL Server's Server= takes the whole
#    [tcp:]host[\instance][,port] spec, so pass it to sqlcmd -S verbatim.
server=$(ado_get server "$url");   [ -n "$server" ] || server=$(ado_get "data source" "$url")
dbname=$(ado_get database "$url"); [ -n "$dbname" ] || dbname=$(ado_get "initial catalog" "$url")
trust=$(ado_get trustservercertificate "$url")
encrypt=$(ado_get encrypt "$url")
[ -n "$server" ] || { echo "no Server in connection_url: $url" >&2; exit 1; }

# Map connection-string options to sqlcmd flags.
extra=()
case "${trust,,}"   in true|yes|1)                  extra+=(-C) ;; esac
case "${encrypt,,}" in true|yes|1|strict|mandatory) extra+=(-N) ;; esac

case "$mode" in
  --sqlcmd)
    command -v sqlcmd >/dev/null || { echo "sqlcmd not found" >&2; exit 1; }
    echo "Role $role — $src creds, ~${remaining}s left; reconnect after expiry." >&2
    # password via env (kept out of argv)
    SQLCMDPASSWORD="$pass" exec sqlcmd -S "$server" -d "$dbname" -U "$user" "${extra[@]}"
    ;;
  --export)
    sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
    echo "export SQLCMDSERVER=$(sq "$server") SQLCMDDBNAME=$(sq "$dbname") SQLCMDUSER=$(sq "$user") SQLCMDPASSWORD=$(sq "$pass")"
    echo "# Role $role — $src creds, ~${remaining}s left; re-run after expiry" >&2
    ;;
  *)
    # ADO.NET connection string with the dynamic creds substituted. Brace-quote
    # user/password so special characters don't break the key=value;… parse.
    filled=${url//'{{username}}'/\{$user\}}
    filled=${filled//'{{password}}'/\{$pass\}}
    printf '%s\n' "$filled"
    echo "Role $role — $src creds, ~${remaining}s left (dynamic creds expire — reconnect after)." >&2
    ;;
esac
