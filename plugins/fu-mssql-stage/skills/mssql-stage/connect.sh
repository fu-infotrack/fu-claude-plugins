#!/usr/bin/env bash
# Connect to a SQL Server using Windows (integrated) authentication.
#
#   Windows  ->  sqlcmd -E            (native integrated auth)
#   WSL      ->  sqlcmd.exe -E        (Windows-host sqlcmd via PATH interop;
#                                      the Linux go-sqlcmd cannot do NTLM)
#   other    ->  error                (Windows auth needs Windows or WSL)
#
# Host resolution: -S <host>, else the mssql-stage.winHost config value, else
# prompt for it interactively and persist it to the user config so later runs
# don't ask again. Database: -d <db>, or the first positional arg.
#
# Usage:
#   connect.sh [database] [options] [-- <extra sqlcmd args>]
#
#   -S, --server <host>   target host; falls back to mssql-stage.winHost, else prompt+save
#   -d, --database <db>   database to use (or pass it as the first positional arg)
#   --save                persist the -S host to config (implicit when prompted)
#   --sqlcmd              exec sqlcmd (Windows-host sqlcmd.exe under WSL)
#   --export              print `export SQLCMD*` lines to eval in your shell
#   -- <args>             everything after -- is passed straight to sqlcmd
#
# Examples:
#   connect.sh                                   # Integrated-Security ADO.NET string
#   connect.sh My.Db --sqlcmd                    # open a sqlcmd shell against My.Db
#   connect.sh My.Db --sqlcmd -- -Q "SELECT 1"   # run a query
#   connect.sh -S db.example.com --save          # set + remember the default host
#
# Requires: sqlcmd (on Windows) or a Windows-host sqlcmd.exe on PATH (under WSL).
#           jq only when persisting the host to config.
set -euo pipefail

cfg() { "$(dirname "$0")/../../scripts/fu-config.sh" mssql-stage "$1" 2>/dev/null || true; }

user_cfg="$HOME/.claude/fu-tools/config.json"

# Persist mssql-stage.winHost into the user config, merging with what is there.
persist_host() {
  local val="$1" tmp cur
  command -v jq >/dev/null || { echo "jq not found — cannot save host" >&2; return 1; }
  mkdir -p "$(dirname "$user_cfg")"
  cur="{}"; [ -f "$user_cfg" ] && cur="$(cat "$user_cfg")"
  tmp="$(mktemp)"
  jq --arg v "$val" '.["mssql-stage"] = ((.["mssql-stage"] // {}) + {winHost: $v})' <<<"$cur" >"$tmp" \
    && mv -f "$tmp" "$user_cfg" && echo "saved winHost=$val to $user_cfg" >&2
}

# windows: native Windows shell. wsl: Linux kernel under WSL (has interop). other: Linux/mac.
detect_platform() {
  case "${OS:-}" in Windows_NT) echo windows; return ;; esac
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo windows; return ;; esac
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && { echo wsl; return; }
  echo other
}

mode=""; server=""; database=""; save=0; passthru=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sqlcmd|--export) mode="$1" ;;
    -S|--server)   server="$2"; shift ;;
    -d|--database) database="$2"; shift ;;
    --save)        save=1 ;;
    --)            shift; passthru=("$@"); break ;;
    -*)            echo "unknown flag: $1" >&2; exit 2 ;;
    *) if [ -z "$database" ]; then database="$1"; else echo "unexpected arg: $1" >&2; exit 2; fi ;;
  esac
  shift
done

platform="$(detect_platform)"
[ "$platform" = other ] && {
  echo "Windows auth needs Windows or WSL (this shell is plain Linux/macOS)." >&2; exit 1; }

# Resolve host: flag, then config, then prompt + persist.
[ -n "$server" ] || server="$(cfg winHost)"
if [ -z "$server" ]; then
  [ -e /dev/tty ] || { echo "no host: pass -S <host> or set mssql-stage.winHost" >&2; exit 1; }
  printf 'SQL Server host: ' >&2
  read -r server < /dev/tty
  [ -n "$server" ] || { echo "no host entered" >&2; exit 1; }
  persist_host "$server" || true
elif [ "$save" = 1 ]; then
  persist_host "$server" || true
fi

# Under WSL, integrated/NTLM auth needs the Windows-host sqlcmd.exe, reachable by
# name through WSL's PATH interop. On native Windows the sqlcmd on PATH is fine.
bin="sqlcmd"; [ "$platform" = wsl ] && bin="sqlcmd.exe"

case "$mode" in
  --export)
    sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
    # No SQLCMDUSER/SQLCMDPASSWORD -> sqlcmd defaults to a trusted (integrated) connection.
    echo "export SQLCMDSERVER=$(sq "$server") SQLCMDDBNAME=$(sq "${database:-master}")"
    [ "$platform" = wsl ] && echo "# WSL: use $bin (the Windows sqlcmd) — the Linux sqlcmd cannot do Windows auth" >&2
    ;;
  --sqlcmd)
    command -v "$bin" >/dev/null || {
      echo "$bin not found" >&2
      [ "$platform" = wsl ] && echo "install sqlcmd on Windows and enable WSL PATH interop" >&2
      exit 1; }
    echo "Windows auth ($platform) -> $server${database:+ / $database}" >&2
    args=(-S "$server" -E -C); [ -n "$database" ] && args+=(-d "$database")
    # cd to a Windows-backed dir under WSL so the .exe does not warn about the UNC cwd.
    [ "$platform" = wsl ] && cd /mnt/c 2>/dev/null || true
    exec "$bin" "${args[@]}" "${passthru[@]}"
    ;;
  *)
    printf 'Server=%s;%sIntegrated Security=true;TrustServerCertificate=true;\n' \
      "$server" "${database:+Database=$database;}"
    echo "Windows auth ($platform) -> $server${database:+ / $database}" >&2
    ;;
esac
