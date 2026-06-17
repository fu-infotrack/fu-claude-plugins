#!/usr/bin/env bash
# Build a SQL Server connection from Vault's database secrets engine, starting from
# the database config: read it for the connection_url AND the roles it allows, pick
# a role, mint dynamic short-lived credentials, then assemble a connection.
#
# Usage:
#   connect.sh [db-config] [role] [--sqlcmd|--export] [--mount <name>]
#
#   [db-config]  Database config name (the path read is <mount>/config/<db-config>).
#                Optional: falls back to the resolved mssql-stage.dbConfig fu-tools value.
#   [role]       Role to generate creds from. Optional: falls back to mssql-stage.role,
#                else if the config allows exactly one role it is used automatically;
#                if it allows several and none is resolved, the roles are listed and we stop.
#   --sqlcmd     exec sqlcmd with the dynamic creds (needs sqlcmd installed).
#   --export     print `export SQLCMD*` lines to eval in your shell.
#   --mount      database secrets engine mount path (default: database / mssql-stage.mount).
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
while [ $# -gt 0 ]; do
  case "$1" in
    --sqlcmd|--export) mode="$1" ;;
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
[ -n "$db" ] || { echo "no db-config given and mssql-stage.dbConfig not configured" >&2; exit 2; }

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

# 1. Start from the database config: connection_url + the roles it allows.
config_json=$(vault read -format=json "$mount/config/$db")
raw_url=$(jq -r '.data.connection_details.connection_url // empty' <<<"$config_json")
[ -n "$raw_url" ] || { echo "no connection_url in $mount/config/$db" >&2; exit 1; }
url=$(urldec "$raw_url")

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
    echo "Role $role — lease ${lease}s, dynamic creds expire, reconnect after." >&2
    # password via env (kept out of argv)
    SQLCMDPASSWORD="$pass" exec sqlcmd -S "$server" -d "$dbname" -U "$user" "${extra[@]}"
    ;;
  --export)
    sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
    echo "export SQLCMDSERVER=$(sq "$server") SQLCMDDBNAME=$(sq "$dbname") SQLCMDUSER=$(sq "$user") SQLCMDPASSWORD=$(sq "$pass")"
    echo "# Role $role — lease ${lease}s, re-run after expiry" >&2
    ;;
  *)
    # ADO.NET connection string with the dynamic creds substituted. Brace-quote
    # user/password so special characters don't break the key=value;… parse.
    filled=${url//'{{username}}'/\{$user\}}
    filled=${filled//'{{password}}'/\{$pass\}}
    printf '%s\n' "$filled"
    echo "Role $role — lease ${lease}s (dynamic creds expire — reconnect after)." >&2
    ;;
esac
