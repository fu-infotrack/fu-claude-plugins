#!/usr/bin/env bash
# Tests for scripts/install.sh and scripts/uninstall.sh — the settings.json
# patching contract. No framework — run:
#   bash plugins/fu-statusline/test/install.test.sh
#
# Every case runs against a throwaway HOME, so nothing here touches the real
# ~/.claude/settings.json.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
UNINSTALL="$ROOT/scripts/uninstall.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

eq() { # eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1
    expected: <$2>
    actual:   <$3>"; fi
}
is_true()  { if [ "$2" = "true" ];  then ok; else bad "$1 (expected true, got <$2>)";  fi; }
is_false() { if [ "$2" = "false" ]; then ok; else bad "$1 (expected false, got <$2>)"; fi; }

SANDBOX=""
# Each case gets a clean HOME. CLAUDE_CONFIG_DIR is left unset so the scripts
# derive ~/.claude themselves — that path is part of the contract.
new_home() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX"
  unset CLAUDE_CONFIG_DIR
  export CLAUDE_PLUGIN_ROOT="$ROOT"
  mkdir -p "$HOME/.claude"
}
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

SETTINGS() { printf '%s' "$HOME/.claude/settings.json"; }
TARGET() { printf '%s' "$HOME/.claude/statusline/statusline.sh"; }
PREV() { printf '%s' "$HOME/.claude/statusline/previous-statusline.json"; }

sl() { jq -r "$1" "$(SETTINGS)" 2>/dev/null; }

echo "== install: fresh machine, no settings.json =="
new_home
rm -f "$(SETTINGS)"
out=$(bash "$INSTALL" 2>&1); rc=$?
eq "exit 0" "0" "$rc"
eq "statusLine.command is the stable tilde path" "~/.claude/statusline/statusline.sh" "$(sl '.statusLine.command')"
eq "statusLine.type" "command" "$(sl '.statusLine.type')"
if [ -x "$(TARGET)" ]; then ok; else bad "renderer not installed executable at $(TARGET)"; fi
if grep -q 'fu-statusline' "$(TARGET)"; then ok; else bad "installed renderer lost its marker"; fi
if cmp -s "$ROOT/statusline.sh" "$(TARGET)"; then ok; else bad "installed renderer differs from the plugin copy"; fi
cleanup

echo "== install: preserves unrelated settings keys =="
new_home
cat >"$(SETTINGS)" <<'JSON'
{ "model": "opus", "permissions": { "allow": ["Bash(ls:*)"] } }
JSON
bash "$INSTALL" >/dev/null 2>&1
eq "model preserved" "opus" "$(sl '.model')"
eq "permissions preserved" "Bash(ls:*)" "$(sl '.permissions.allow[0]')"
eq "statusLine set" "~/.claude/statusline/statusline.sh" "$(sl '.statusLine.command')"
cleanup

echo "== install: displaces a foreign statusLine and records it =="
new_home
cat >"$(SETTINGS)" <<'JSON'
{ "statusLine": { "type": "command", "command": "npx -y ccstatusline@latest", "refreshInterval": 10 } }
JSON
bash "$INSTALL" >/dev/null 2>&1
eq "ours now" "~/.claude/statusline/statusline.sh" "$(sl '.statusLine.command')"
if [ -f "$(PREV)" ]; then ok; else bad "no previous-statusline.json written"; fi
eq "previous value recorded" "npx -y ccstatusline@latest" "$(jq -r '.command' "$(PREV)")"

echo "== install: idempotent — second run keeps the original backup =="
bash "$INSTALL" >/dev/null 2>&1; rc=$?
eq "exit 0 on reinstall" "0" "$rc"
eq "still ours" "~/.claude/statusline/statusline.sh" "$(sl '.statusLine.command')"
eq "backup still the FOREIGN value, not our own" "npx -y ccstatusline@latest" "$(jq -r '.command' "$(PREV)")"
cleanup

echo "== install: keeps user-tuned padding/refreshInterval on reinstall =="
new_home
bash "$INSTALL" >/dev/null 2>&1
jq '.statusLine.refreshInterval = 30 | .statusLine.padding = 2' "$(SETTINGS)" >"$(SETTINGS).t" && mv "$(SETTINGS).t" "$(SETTINGS)"
bash "$INSTALL" >/dev/null 2>&1
eq "refreshInterval kept" "30" "$(sl '.statusLine.refreshInterval')"
eq "padding kept" "2" "$(sl '.statusLine.padding')"
cleanup

echo "== install: refuses to clobber a foreign file at the install path =="
new_home
mkdir -p "$HOME/.claude/statusline"
printf '#!/bin/sh\necho someone elses script\n' >"$(TARGET)"
before=$(cat "$(TARGET)")
echo '{"model":"opus"}' >"$(SETTINGS)"
out=$(bash "$INSTALL" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then ok; else bad "expected non-zero exit when target is a foreign file"; fi
eq "foreign file untouched" "$before" "$(cat "$(TARGET)")"
eq "settings untouched" "null" "$(sl '.statusLine')"
cleanup

echo "== install: adopts a hand-installed renderer from before the plugin existed =="
new_home
mkdir -p "$HOME/.claude/statusline"
# The pre-plugin renderer: same script, no marker comment.
grep -v 'fu-statusline' "$ROOT/statusline.sh" >"$(TARGET)"
chmod 755 "$(TARGET)"
bash "$INSTALL" >/dev/null 2>&1; rc=$?
eq "exit 0 without --force" "0" "$rc"
if grep -q 'fu-statusline' "$(TARGET)"; then ok; else bad "pre-plugin renderer was not upgraded"; fi
cleanup

echo "== install: a wrapper that merely mentions the cache is still foreign =="
new_home
mkdir -p "$HOME/.claude/statusline"
cat >"$(TARGET)" <<'SH'
#!/usr/bin/env bash
# A/B harness: run both renderers, clear ~/.cache/cc-statusline between runs.
exec npx -y ccstatusline@latest
SH
before=$(cat "$(TARGET)")
bash "$INSTALL" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok; else bad "expected refusal — a wrapper is not our renderer"; fi
eq "wrapper untouched" "$before" "$(cat "$(TARGET)")"
cleanup

echo "== install: --force overwrites a foreign file at the install path =="
new_home
mkdir -p "$HOME/.claude/statusline"
printf '#!/bin/sh\necho someone elses script\n' >"$(TARGET)"
bash "$INSTALL" --force >/dev/null 2>&1; rc=$?
eq "exit 0 with --force" "0" "$rc"
if grep -q 'fu-statusline' "$(TARGET)"; then ok; else bad "--force did not install the renderer"; fi
cleanup

echo "== install: invalid settings.json is an error, not a rewrite =="
new_home
printf '{ this is not json' >"$(SETTINGS)"
before=$(cat "$(SETTINGS)")
out=$(bash "$INSTALL" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then ok; else bad "expected non-zero exit on malformed settings.json"; fi
eq "settings left byte-identical" "$before" "$(cat "$(SETTINGS)")"
cleanup

echo "== install: writes a pre-change settings snapshot =="
new_home
echo '{"model":"opus"}' >"$(SETTINGS)"
bash "$INSTALL" >/dev/null 2>&1
if [ -f "$HOME/.claude/statusline/settings.json.bak" ]; then ok; else bad "no settings.json.bak snapshot"; fi
eq "snapshot is the pre-change content" "null" "$(jq -r '.statusLine' "$HOME/.claude/statusline/settings.json.bak")"
cleanup

echo "== uninstall: restores the displaced statusLine =="
new_home
cat >"$(SETTINGS)" <<'JSON'
{ "model": "opus", "statusLine": { "type": "command", "command": "npx -y ccstatusline@latest", "refreshInterval": 10 } }
JSON
bash "$INSTALL" >/dev/null 2>&1
bash "$UNINSTALL" >/dev/null 2>&1; rc=$?
eq "exit 0" "0" "$rc"
eq "original restored" "npx -y ccstatusline@latest" "$(sl '.statusLine.command')"
eq "original refreshInterval restored" "10" "$(sl '.statusLine.refreshInterval')"
eq "unrelated keys survive" "opus" "$(sl '.model')"
if [ -f "$(PREV)" ]; then bad "previous-statusline.json should be consumed by uninstall"; else ok; fi
if [ -e "$(TARGET)" ]; then bad "installed renderer should be removed"; else ok; fi
cleanup

echo "== uninstall: no prior statusLine — key is removed, not nulled =="
new_home
echo '{"model":"opus"}' >"$(SETTINGS)"
bash "$INSTALL" >/dev/null 2>&1
bash "$UNINSTALL" >/dev/null 2>&1
is_false "statusLine key gone" "$(jq 'has("statusLine")' "$(SETTINGS)")"
eq "unrelated keys survive" "opus" "$(sl '.model')"
cleanup

echo "== uninstall: leaves a statusLine that is not ours alone =="
new_home
bash "$INSTALL" >/dev/null 2>&1
jq '.statusLine.command = "/opt/other/statusline.sh"' "$(SETTINGS)" >"$(SETTINGS).t" && mv "$(SETTINGS).t" "$(SETTINGS)"
bash "$UNINSTALL" >/dev/null 2>&1; rc=$?
eq "exit 0" "0" "$rc"
eq "foreign statusLine untouched" "/opt/other/statusline.sh" "$(sl '.statusLine.command')"
cleanup

echo "== uninstall: --keep-script leaves the renderer in place =="
new_home
bash "$INSTALL" >/dev/null 2>&1
bash "$UNINSTALL" --keep-script >/dev/null 2>&1
if [ -x "$(TARGET)" ]; then ok; else bad "--keep-script removed the renderer anyway"; fi
is_false "statusLine still removed" "$(jq 'has("statusLine")' "$(SETTINGS)")"
cleanup

echo "== uninstall: nothing installed is a no-op, not an error =="
new_home
echo '{"model":"opus"}' >"$(SETTINGS)"
out=$(bash "$UNINSTALL" 2>&1); rc=$?
eq "exit 0" "0" "$rc"
eq "settings untouched" "opus" "$(sl '.model')"
cleanup

echo "== uninstall: --purge removes the cache directory =="
new_home
bash "$INSTALL" >/dev/null 2>&1
mkdir -p "$HOME/.cache/cc-statusline" && touch "$HOME/.cache/cc-statusline/abc.tok"
bash "$UNINSTALL" --purge >/dev/null 2>&1
if [ -e "$HOME/.cache/cc-statusline" ]; then bad "--purge left the cache directory"; else ok; fi
cleanup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
