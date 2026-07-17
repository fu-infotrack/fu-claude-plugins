#!/usr/bin/env bash
# PreToolUse Bash guard — block git commit on protected branches.
# Config from fu-tools layered config, tool key "dev-guards" (resolved via
# fu-config.sh walking up from cwd = the commit dir; project over user):
#   protected_branches  regex of branches to block; empty/unset -> default below
#   repo_filter         regex on origin remote URL; empty/unset -> all repos
# Env overrides PROTECTED_BRANCHES / REPO_FILTER take precedence (used by tests).
DEFAULT_BRANCHES='^(main|master|develop)$'

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Segment + head-match so a chained commit (`git fetch && git commit -m x`) or a
# wrapped one can't slip past a start-anchored grep.
source "$here/lib/git-guard.sh"
cmd_invokes "$cmd" 'git commit' || exit 0

# Resolve config from fu-tools unless the matching env var is already set.
fu_config="$here/../../scripts/fu-config.sh"
fu_get() { [ -f "$fu_config" ] && bash "$fu_config" dev-guards "$1" 2>/dev/null || true; }

[ -z "${PROTECTED_BRANCHES+x}" ] && PROTECTED_BRANCHES="$(fu_get protected_branches)"
[ -z "$PROTECTED_BRANCHES" ] && PROTECTED_BRANCHES="$DEFAULT_BRANCHES"

[ -z "${REPO_FILTER+x}" ] && REPO_FILTER="$(fu_get repo_filter)"

# Scope to matching repos when a filter is set; empty filter = every repo.
if [ -n "${REPO_FILTER:-}" ]; then
  remote=$(git remote get-url origin 2>/dev/null)
  echo "$remote" | grep -qiE "$REPO_FILTER" || exit 0
fi

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

if echo "$branch" | grep -qE "$PROTECTED_BRANCHES"; then
  jq -nc --arg b "$branch" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Direct commits to '\''"+$b+"'\'' are forbidden. Create a branch first.")
    }
  }'
  exit 2
fi
