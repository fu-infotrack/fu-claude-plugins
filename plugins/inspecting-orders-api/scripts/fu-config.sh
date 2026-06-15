#!/usr/bin/env bash
# Resolve a fu-tools config value: project .claude/.fu-tools.json (walk up) over
# ~/.claude/fu-tools/config.json. Usage: fu-config.sh <tool> <key>  -> value or empty.
set -euo pipefail
tool="${1:?tool}"; key="${2:?key}"
user_cfg="$HOME/.claude/fu-tools/config.json"
proj_cfg=""; dir="$PWD"
while :; do
  [ -f "$dir/.claude/.fu-tools.json" ] && { proj_cfg="$dir/.claude/.fu-tools.json"; break; }
  [ "$dir" = "/" ] && break
  dir="$(dirname "$dir")"
done
u="{}"; [ -f "$user_cfg" ] && u="$(cat "$user_cfg")"
p="{}"; [ -n "$proj_cfg" ] && p="$(cat "$proj_cfg")"
jq -rn --argjson u "$u" --argjson p "$p" --arg t "$tool" --arg k "$key" \
  '(($u[$t] // {}) * ($p[$t] // {}))[$k] // empty'
