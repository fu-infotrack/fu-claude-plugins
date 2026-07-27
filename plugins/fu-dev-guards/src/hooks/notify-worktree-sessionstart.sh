#!/usr/bin/env bash
# SessionStart hook — when a session opens in a protected (main) checkout, say so
# up front instead of letting the session discover it by being denied.
#
# Why this exists: in a protected dir Write/Edit, branch switching and commits on
# main are all denied, so "edit in place" cannot work — and a session that learns
# this only from a denial may route around the Write/Edit guard via Bash instead
# of doing the right thing. Stating the rule first avoids both.
#
# Advisory only: the PreToolUse guards remain the enforcement. Silent unless the
# session cwd is inside a protected root (and not exempt), so unprotected repos
# and sessions already inside a worktree see nothing.
# Env override (tests): GUARD_CWD.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib/protected-dirs.sh"
pd_load

cwd="${GUARD_CWD:-$PWD}/"
pd_is_protected "$cwd" || exit 0

read -r -d '' notice <<'TXT'
fu-dev-guards: this session's working directory is a PROTECTED (main) checkout.
Denied here: Write/Edit on any file, git checkout/switch/gh pr checkout, and git commit on main.
Concurrent sessions also share this checkout's single index and HEAD, so editing in place
would let one session's `git add -A` swallow another's half-finished work.

Call EnterWorktree (name: <branch-name>) BEFORE creating, editing or deleting files.
Then branch, commit and push inside the worktree and land via PR (squash-merged).
Do not work around this by writing files through Bash instead.
TXT

jq -nc --arg c "$notice" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $c
  }
}'
