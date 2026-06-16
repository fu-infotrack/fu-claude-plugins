#!/usr/bin/env bash
# PreToolUse EnterWorktree guard — deny path outside .claude/worktrees/.
p=$(jq -r '.tool_input.path // ""' 2>/dev/null)
if [ -n "$p" ] && ! echo "$p" | grep -qE '\.claude/worktrees/'; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Worktrees must live under .claude/worktrees/. Refusing to enter worktree outside that path."
    }
  }'
  exit 2
fi
