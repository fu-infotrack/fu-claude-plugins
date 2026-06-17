#!/usr/bin/env bash
# Build a Postgres connection from Vault's database secrets engine, starting from
# the database config: read it for the connection_url AND the roles it allows,
# pick a role, mint dynamic short-lived credentials, then assemble a conn string.
#
# Usage:
#   connect.sh [db-config] [role] [--psql|--export] [--mount <name>]
#
#   [db-config]  Database config name (the path read is <mount>/config/<db-config>).
#                Optional: falls back to the resolved pg-stage.dbConfig fu-tools value.
#   [role]       Role to generate creds from. Optional: falls back to pg-stage.role,
#                else if the config allows exactly one role it is used automatically;
#                if it allows several and none is resolved, the roles are listed and we stop.
#   --psql       exec psql with the dynamic creds (needs psql installed).
#   --export     print `export PG*` lines to eval in your shell.
#   --mount      database secrets engine mount path (default: database / pg-stage.mount).
#
# Examples:
#   connect.sh                       # db-config + role from fu-tools config
#   connect.sh <db-config>           # auto-role, print conn string
#   connect.sh <db-config> <role>    # explicit role
#   connect.sh <db-config> --psql    # open a shell
#   eval "$(connect.sh --export)"    # load PG* into shell
#
# Requires: vault (authenticated, VAULT_ADDR set), jq.
set -euo pipefail

command -v vault >/dev/null || { echo "vault CLI not found" >&2; exit 1; }
command -v jq    >/dev/null || { echo "jq not found" >&2; exit 1; }

# fu-tools config resolver (sibling plugin script); empty if unavailable.
cfg() { "$(dirname "$0")/../../scripts/fu-config.sh" pg-stage "$1" 2>/dev/null || true; }

# VAULT_ADDR: honour the environment, else resolve from config. Must be EXPORTED
# so the `vault` child process sees it (otherwise it falls back to 127.0.0.1:8200).
VAULT_ADDR="${VAULT_ADDR:-$(cfg vaultAddr)}"
: "${VAULT_ADDR:?VAULT_ADDR not set — set it or configure pg-stage.vaultAddr, then \`vault login\`}"
export VAULT_ADDR

mount=""
mode=""
db=""
role=""
while [ $# -gt 0 ]; do
  case "$1" in
    --psql|--export) mode="$1" ;;
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
[ -n "$db" ] || { echo "no db-config given and pg-stage.dbConfig not configured" >&2; exit 2; }

# percent-encode a string for safe use in a URI userinfo component
urlenc() {
  local s=$1 out="" i c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9._~-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}
# single-quote a string for safe eval in `export VAR='...'`
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# 1. Start from the database config: connection_url + the roles it allows.
config_json=$(vault read -format=json "$mount/config/$db")
url=$(jq -r '.data.connection_details.connection_url // empty' <<<"$config_json")
[ -n "$url" ] || { echo "no connection_url in $mount/config/$db" >&2; exit 1; }

# 2. Resolve the role from allowed_roles unless the caller named one.
if [ -z "$role" ]; then
  mapfile -t roles < <(jq -r '.data.allowed_roles[]? // empty' <<<"$config_json")
  case ${#roles[@]} in
    0) echo "$mount/config/$db allows no roles — pass a role explicitly" >&2; exit 1 ;;
    1) role="${roles[0]}" ;;
    *) echo "$mount/config/$db allows multiple roles — pick one:" >&2
       printf '  %s\n' "${roles[@]}" >&2; exit 1 ;;
  esac
fi

# 3. Mint dynamic credentials from the role.
creds_json=$(vault read -format=json "$mount/creds/$role")
user=$(jq -r '.data.username' <<<"$creds_json")
pass=$(jq -r '.data.password' <<<"$creds_json")
lease=$(jq -r '.lease_duration' <<<"$creds_json")

# 4. Assemble the connection. connection_url is:
#    postgresql://{{username}}:{{password}}@HOST:PORT/DB?params
hostpart=${url#*@}
hostport=${hostpart%%/*}
host=${hostport%%:*}
port=${hostport##*:}; [ "$port" = "$host" ] && port=5432
rest=${hostpart#*/}
dbname=${rest%%\?*}
query=""; [ "$rest" != "$dbname" ] && query="?${rest#*\?}"

euser=$(urlenc "$user")
epass=$(urlenc "$pass")

case "$mode" in
  --psql)
    command -v psql >/dev/null || { echo "psql not found" >&2; exit 1; }
    echo "Role $role — lease ${lease}s, dynamic creds expire, reconnect after." >&2
    # password via env (kept out of argv); URI keeps the query params (e.g. sslmode)
    PGPASSWORD="$pass" exec psql "postgresql://${euser}@${host}:${port}/${dbname}${query}"
    ;;
  --export)
    echo "export PGHOST=$(sq "$host") PGPORT=$(sq "$port") PGDATABASE=$(sq "$dbname") PGUSER=$(sq "$user") PGPASSWORD=$(sq "$pass")"
    echo "# Role $role — lease ${lease}s, re-run after expiry" >&2
    ;;
  *)
    echo "postgresql://${euser}:${epass}@${host}:${port}/${dbname}${query}"
    echo "Role $role — lease ${lease}s (dynamic creds expire — reconnect after)." >&2
    ;;
esac
