#!/usr/bin/env bash
# PreToolUse hook: run dotnet format on staged .cs files before git commit.
# Detects .slnx > .sln > .csproj walking up the directory tree.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "dotnet-format-precommit: jq is required but not installed" >&2; exit 2; }

deny() {
  local reason=$1
  jq -nc --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 2
}

input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

[ "$tool" = "Bash" ] || exit 0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Segment + head-match: catches wrapped/substituted commits the old prefix regex
# missed (`env X=1 git commit`, `$(git commit ...)`), not just separator-chained.
source "$here/lib/git-guard.sh"
cmd_invokes "$cmd" 'git commit' || exit 0
echo "$cmd" | grep -qE '\bgit\s+commit\b.*--amend' && exit 0

project_file=""
dir=$(pwd)
for _ in 1 2 3 4 5 6; do
  candidate=$(ls "$dir"/*.slnx 2>/dev/null | head -1)
  [ -z "$candidate" ] && candidate=$(ls "$dir"/*.sln 2>/dev/null | head -1)
  [ -z "$candidate" ] && candidate=$(ls "$dir"/*.csproj 2>/dev/null | head -1)
  if [ -n "$candidate" ]; then project_file="$candidate"; break; fi
  parent=$(dirname "$dir"); [ "$parent" = "$dir" ] && break; dir=$parent
done
[ -n "$project_file" ] || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Note: `git commit -a` auto-stages AFTER PreToolUse, so dirty .cs files not
# yet in the index are invisible here. Hook only formats what is already staged.
mapfile -d '' staged < <(git diff --cached --name-only --diff-filter=ACMR -z -- '*.cs')
[ ${#staged[@]} -gt 0 ] || exit 0

mapfile -d '' unstaged_dirty < <(git diff --name-only -z -- '*.cs')
partial=()
for f in "${staged[@]}"; do
  for u in "${unstaged_dirty[@]}"; do
    [ "$f" = "$u" ] && partial+=("$f")
  done
done
if [ ${#partial[@]} -gt 0 ]; then
  deny "Partially staged .cs files would be clobbered by dotnet format: ${partial[*]}. Stage fully or stash."
fi

# --no-restore is intentionally OMITTED: when a project is unrestored, the
# analyser cannot resolve external types and false-positive-removes their
# `using` directives. Cost: a few seconds per commit for the assets check.
common=("--include" "${staged[@]}" "--verbosity" "quiet")

run_pass() {
  local mode=$1; shift
  local err rc
  err=$(timeout 120 dotnet format "$mode" "$project_file" "${common[@]}" "$@" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    deny "dotnet format $mode failed (exit $rc): ${err: -1800}"
  fi
}

run_pass whitespace
run_pass style
# Exclude Obsolete-member diagnostics so the analyzer's code-fix provider
# (if any) cannot cascade-rewrite call sites. Verified harmless on .NET 10
# SDK 10.0.300 — kept as defensive belt-and-braces for future analyzer drops.
run_pass analyzers --exclude-diagnostics CS0612 CS0618 CS0619

modified=()
for f in "${staged[@]}"; do
  git diff --quiet -- "$f" || modified+=("$f")
done

if [ ${#modified[@]} -gt 0 ]; then
  git add -- "${modified[@]}" || deny "git add failed after dotnet format reformatted: ${modified[*]}. Re-stage manually and retry."
  printf 'dotnet format: reformatted %d file(s): %s\n' \
    "${#modified[@]}" "$(IFS=,; echo "${modified[*]}")" >&2
fi
exit 0
