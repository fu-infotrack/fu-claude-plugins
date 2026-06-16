#!/usr/bin/env bash
# PreToolUse Bash guard — deny git worktree add outside .claude/worktrees/.
cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null)
if echo "$cmd" | grep -qE '^\s*git\s+worktree\s+add\b'; then
  if ! echo "$cmd" | grep -qE '\.claude/worktrees/'; then
    jq -nc '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Worktrees must live under .claude/worktrees/. Prefer the EnterWorktree tool (name: <branch-name>) — harness-native, switches session cwd, tracks cleanup. Fall back to: git worktree add .claude/worktrees/<branch-name> -b <branch-name> only if you need a specific base ref."
      }
    }'
    exit 2
  fi
fi
