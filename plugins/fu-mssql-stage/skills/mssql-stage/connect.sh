#!/usr/bin/env bash
# Connect to a SQL Server using Windows (integrated) authentication.
#
#   Windows  ->  sqlcmd -E            (native integrated auth)
#   WSL      ->  sqlcmd.exe -E        (Windows-host sqlcmd via PATH interop;
#                                      the Linux go-sqlcmd cannot do NTLM)
#   other    ->  error                (Windows auth needs Windows or WSL)
#
# Hosts are NAMED in config (like fu-k8dash clusters). -S takes a name or a
# literal host:
#   -S <name>   -> the mssql-stage.<name>.host config value
#   -S <host>   -> used literally when it matches no configured name
#   (omitted)   -> the mssql-stage.defaultHost name; else a legacy `winHost`;
#                  else prompt for a host and persist it as 'default'.
# Database: -d <db>, or the first positional arg.
#
# Usage:
#   connect.sh [database] [options] [-- <extra sqlcmd args>]
#
#   -S, --server <name|host>  named host from config, or a literal host
#   -d, --database <db>       database (or pass it as the first positional arg)
#   --save-as <name>          persist the resolved host under <name> in config
#   --default                 with --save-as: also make it the defaultHost;
#                             alone with -S <name>: point defaultHost at <name>
#   --sqlcmd                  exec sqlcmd (Windows-host sqlcmd.exe under WSL)
#   --export                  print `export SQLCMD*` lines to eval in your shell
#   -- <args>                 everything after -- is passed straight to sqlcmd
#
# Examples:
#   connect.sh                                          # defaultHost, ADO.NET string
#   connect.sh -S idp-ro My.Db --sqlcmd                 # named host, open a shell
#   connect.sh -S db.example.com --save-as qa --default # register + make default
#   connect.sh My.Db --sqlcmd -- -Q "SELECT 1"          # query the default host
#
# Requires: sqlcmd (on Windows) or a Windows-host sqlcmd.exe on PATH (under WSL).
#           jq only when persisting a host to config.
set -euo pipefail

cfg() { "$(dirname "$0")/../../scripts/fu-config.sh" mssql-stage "$1" 2>/dev/null || true; }

user_cfg="$HOME/.claude/fu-tools/config.json"

# Merge a jq program into the user config (creating it if absent), preserving
# every other tool's keys.
cfg_merge() {
  local prog="$1"; shift
  command -v jq >/dev/null || { echo "jq not found — cannot write config" >&2; return 1; }
  mkdir -p "$(dirname "$user_cfg")"
  local cur="{}"; [ -f "$user_cfg" ] && cur="$(cat "$user_cfg")"
  local tmp; tmp="$(mktemp)"
  jq "$@" "$prog" <<<"$cur" >"$tmp" && mv -f "$tmp" "$user_cfg"
}

# persist_host <name> <host> [set_default 0|1]
persist_host() {
  local name="$1" val="$2" setdef="${3:-0}"
  cfg_merge '
      .["mssql-stage"] = ((.["mssql-stage"] // {}) + { ($n): { host: $v } })
    | if $d == 1 then .["mssql-stage"].defaultHost = $n else . end
  ' --arg n "$name" --arg v "$val" --argjson d "$setdef" \
    && echo "saved host '$name'=$val$([ "$setdef" = 1 ] && printf ' (defaultHost)')" >&2
}

# set_default_host <name>
set_default_host() {
  cfg_merge '.["mssql-stage"].defaultHost = $n' --arg n "$1" && echo "defaultHost -> $1" >&2
}

# windows: native Windows shell. wsl: Linux kernel under WSL (has interop). other: Linux/mac.
detect_platform() {
  case "${OS:-}" in Windows_NT) echo windows; return ;; esac
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo windows; return ;; esac
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && { echo wsl; return; }
  echo other
}

mode=""; server=""; database=""; save_as=""; set_default=0; passthru=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sqlcmd|--export) mode="$1" ;;
    -S|--server)   server="$2"; shift ;;
    -d|--database) database="$2"; shift ;;
    --save-as)     save_as="$2"; shift ;;
    --default)     set_default=1 ;;
    --)            shift; passthru=("$@"); break ;;
    -*)            echo "unknown flag: $1" >&2; exit 2 ;;
    *) if [ -z "$database" ]; then database="$1"; else echo "unexpected arg: $1" >&2; exit 2; fi ;;
  esac
  shift
done

platform="$(detect_platform)"
[ "$platform" = other ] && {
  echo "Windows auth needs Windows or WSL (this shell is plain Linux/macOS)." >&2; exit 1; }

# Selection: -S value, else the configured defaultHost name.
sel="$server"
[ -n "$sel" ] || sel="$(cfg defaultHost)"

# Resolve the selection to a concrete host: named lookup, else literal; with no
# selection at all, fall back to the legacy single-host `winHost` key (pre-0.4.0).
host=""
if [ -n "$sel" ]; then
  host="$(cfg "$sel.host")"          # mssql-stage.<sel>.host
  [ -n "$host" ] || host="$sel"      # not a configured name -> treat as a literal host
else
  host="$(cfg winHost)"              # legacy single-host key
fi

# Nothing resolved -> prompt once, persist it as the 'default' host.
if [ -z "$host" ]; then
  [ -e /dev/tty ] || { echo "no host: pass -S <name|host> or set mssql-stage.defaultHost" >&2; exit 1; }
  printf 'SQL Server host: ' >&2
  read -r host < /dev/tty
  [ -n "$host" ] || { echo "no host entered" >&2; exit 1; }
  persist_host default "$host" 1 || true
fi

# Explicit registration / default switching.
if [ -n "$save_as" ]; then
  persist_host "$save_as" "$host" "$set_default" || true
elif [ "$set_default" = 1 ] && [ -n "$sel" ]; then
  set_default_host "$sel" || true
fi

# Under WSL, integrated/NTLM auth needs the Windows-host sqlcmd.exe, reachable by
# name through WSL's PATH interop. On native Windows the sqlcmd on PATH is fine.
bin="sqlcmd"; [ "$platform" = wsl ] && bin="sqlcmd.exe"

case "$mode" in
  --export)
    sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
    # No SQLCMDUSER/SQLCMDPASSWORD -> sqlcmd defaults to a trusted (integrated) connection.
    echo "export SQLCMDSERVER=$(sq "$host") SQLCMDDBNAME=$(sq "${database:-master}")"
    [ "$platform" = wsl ] && echo "# WSL: use $bin (the Windows sqlcmd) — the Linux sqlcmd cannot do Windows auth" >&2
    ;;
  --sqlcmd)
    command -v "$bin" >/dev/null || {
      echo "$bin not found" >&2
      [ "$platform" = wsl ] && echo "install sqlcmd on Windows and enable WSL PATH interop" >&2
      exit 1; }
    echo "Windows auth ($platform) -> $host${database:+ / $database}" >&2
    args=(-S "$host" -E -C); [ -n "$database" ] && args+=(-d "$database")
    # cd to a Windows-backed dir under WSL so the .exe does not warn about the UNC cwd.
    [ "$platform" = wsl ] && cd /mnt/c 2>/dev/null || true
    exec "$bin" "${args[@]}" "${passthru[@]}"
    ;;
  *)
    printf 'Server=%s;%sIntegrated Security=true;TrustServerCertificate=true;\n' \
      "$host" "${database:+Database=$database;}"
    echo "Windows auth ($platform) -> $host${database:+ / $database}" >&2
    ;;
esac
