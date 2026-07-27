#!/usr/bin/env bash
# Tests for the shared git-guard helper and the hooks that use it.
# No framework — run: bash plugins/fu-dev-guards/test/git-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$HERE/../src/hooks"
source "$HOOKS/lib/git-guard.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# should_match  <desc> <cmd> <verb>...   — expect cmd_invokes to return 0
should_match() {
  local desc=$1 cmd=$2; shift 2
  if cmd_invokes "$cmd" "$@"; then ok; else bad "expected MATCH — $desc :: <$cmd>"; fi
}
# should_miss  <desc> <cmd> <verb>...   — expect cmd_invokes to return 1
should_miss() {
  local desc=$1 cmd=$2; shift 2
  if cmd_invokes "$cmd" "$@"; then bad "expected NO match — $desc :: <$cmd>"; else ok; fi
}

CO=('git checkout' 'git switch' 'gh pr checkout')

echo "== cmd_invokes: checkout/switch — positives =="
should_match "plain"                  'git checkout main'                              "${CO[@]}"
should_match "leading whitespace"     '   git switch main'                             "${CO[@]}"
should_match "chained && (the bypass)" 'git fetch origin && git checkout -b x origin/main' "${CO[@]}"
should_match "chained ;"              'git fetch; git switch main'                     "${CO[@]}"
should_match "chained ||"             'git status || git checkout .'                   "${CO[@]}"
should_match "env wrapper"            'env FOO=1 git switch main'                      "${CO[@]}"
should_match "assignment prefix"      'FOO=1 BAR=2 git checkout x'                     "${CO[@]}"
should_match "sudo wrapper"           'sudo git checkout main'                         "${CO[@]}"
should_match "command substitution"   'y=$(git checkout main)'                         "${CO[@]}"
should_match "pipe into xargs"        'echo main | xargs git checkout'                 "${CO[@]}"
should_match "backslash alias bypass" '\git checkout main'                             "${CO[@]}"
should_match "gh pr checkout"         'gh pr checkout 42'                              "${CO[@]}"
should_match "chained gh pr checkout" 'git fetch && gh pr checkout 42'                 "${CO[@]}"
should_match "multi-space"            'git   checkout main'                            "${CO[@]}"
should_match "tab-separated"          $'git\tcheckout main'                            "${CO[@]}"
should_match "newline-separated"      $'git status\ngit checkout main'                 "${CO[@]}"

echo "== cmd_invokes: checkout/switch — negatives =="
should_miss  "verb in -m message"     "git commit -m 'checkout done'"                  "${CO[@]}"
should_miss  "verb in --grep arg"     "git log --grep 'git checkout'"                  "${CO[@]}"
should_miss  "verb in echo string"    'echo "git checkout"'                            "${CO[@]}"
should_miss  "checkout-index plumbing" 'git checkout-index --all'                      "${CO[@]}"
should_miss  "filename lookalike"     'cat git-checkout.txt'                           "${CO[@]}"
should_miss  "git config alias"       'git config alias.co checkout'                   "${CO[@]}"

echo "== cmd_invokes: quote-aware — no false block on quoted prose =="
# Boundary chars inside quotes are literal, so prose in a quoted argument cannot
# trigger a block. The `)` case below was a REAL false positive in v0.2.0: it
# denied a plain `echo` while probing the guards.
should_miss  "paren in quoted echo"   'echo "=== A) git checkout -b x ==="'             "${CO[@]}"
should_miss  "&& inside quotes"       'echo "a && git checkout b"'                     "${CO[@]}"
should_miss  "; inside quotes"        'echo "a; git switch b"'                         "${CO[@]}"
should_miss  "pipe inside quotes"     'grep -r "x | git checkout" .'                   "${CO[@]}"
should_miss  "parens inside quotes"   'printf "%s" "(git checkout main)"'              "${CO[@]}"
should_miss  "brace inside quotes"    'echo "{git checkout}"'                          "${CO[@]}"
should_miss  "verb in commit body"    "git commit -m 'ran git checkout; then switch'"   "${CO[@]}"

echo "== cmd_invokes: quote-aware still catches real commands =="
should_match "substitution in quotes" 'y="$(git checkout main)"'                        "${CO[@]}"
should_match "backticks"              'y=`git checkout main`'                           "${CO[@]}"
should_match "backticks in quotes"    'y="`git switch main`"'                           "${CO[@]}"
should_match "quoted arg then chain"  'echo "safe text" && git checkout main'           "${CO[@]}"
should_match "sh -c payload"          "sh -c 'git checkout main'"                       "${CO[@]}"
should_match "bash -c payload"        'bash -c "git switch main"'                       "${CO[@]}"
should_miss  "sh -c benign payload"   "sh -c 'echo git checkout'"                       "${CO[@]}"
should_match "commit via sh -c"       "sh -c 'git commit -m x'"                         'git commit'

echo "== cmd_invokes: heredoc bodies are data, not commands =="
# Writing docs / a PR body that MENTIONS a guarded verb must not be blocked.
# v0.2.0 denied exactly this while drafting the PR that introduced it.
SQ="'"
HD_QUOTED=$(printf 'cat <<%sEOF%s\ngit checkout -b x\nEOF\n' "$SQ" "$SQ")
HD_BODY=$(printf 'gh pr create --body "$(cat <<%sBODY%s\nran git fetch && git checkout -b x\nBODY\n)"\n' "$SQ" "$SQ")
should_miss  "heredoc quoted delimiter" "$HD_QUOTED"                                     "${CO[@]}"
should_miss  "heredoc bare delimiter"   $'cat <<EOF\ngit checkout -b x\nEOF'             "${CO[@]}"
should_miss  "heredoc <<- indented end" $'cat <<-EOF\n\tgit checkout x\n\tEOF'           "${CO[@]}"
should_miss  "gh pr body heredoc"       "$HD_BODY"                                       "${CO[@]}"
should_miss  "here-string is data"      'grep x <<< "git checkout main"'                 "${CO[@]}"
should_miss  "plain input redirect"     'git status < file.txt'                          "${CO[@]}"
# ...but a substitution inside a bare-delimiter body DOES execute, and anything
# after the terminator is a normal command again.
should_match "substitution in heredoc"  $'cat <<EOF\n$(git checkout main)\nEOF'          "${CO[@]}"
should_match "command after terminator" $'cat <<EOF\ntext\nEOF\ngit checkout main'       "${CO[@]}"
should_match "commit after terminator"  $'cat <<EOF\ntext\nEOF\ngit commit -m x'         'git commit'

echo "== cmd_invokes: git commit =="
should_match "plain commit"           'git commit -m x'                                'git commit'
should_match "chained commit (bypass)" 'git fetch origin main --quiet && git commit -m x' 'git commit'
should_match "assignment + commit"    'GIT_X=1 git commit -m x'                        'git commit'
should_miss  "commit in message"      "git log --grep 'commit'"                        'git commit'
should_miss  "commit-tree plumbing"   'git commit-tree abc123'                         'git commit'
should_miss  "commit in echo"         'echo "please commit"'                           'git commit'

echo "== cmd_invokes: git worktree add =="
should_match "plain worktree add"     'git worktree add /tmp/wt'                       'git worktree add'
should_match "chained worktree add"   'cd repo && git worktree add /tmp/wt -b x'       'git worktree add'
should_miss  "worktree list"          'git worktree list'                              'git worktree add'
should_miss  "worktree remove"        'git worktree remove /tmp/wt'                    'git worktree add'

# ---- end-to-end: the actual hooks, driven via their env seams --------------

# run_hook <hookfile> <json-on-stdin> [VAR=val ...]  -> sets RC, OUT
run_hook() {
  local hook=$1 json=$2; shift 2
  OUT=$(env "$@" bash "$HOOKS/$hook" <<<"$json" 2>/dev/null); RC=$?
}

echo "== e2e: guard-protected-checkout.sh =="
run_hook guard-protected-checkout.sh \
  '{"tool_input":{"command":"git fetch origin && git checkout -b x origin/main"}}' \
  PROTECTED_DIRS=/tmp/protrepo GUARD_CWD=/tmp/protrepo
[ "$RC" -eq 2 ] && ok || bad "checkout: chained bypass should be DENIED (rc=$RC)"

run_hook guard-protected-checkout.sh \
  '{"tool_input":{"command":"git fetch origin && git checkout -b x origin/main"}}' \
  PROTECTED_DIRS=/tmp/protrepo GUARD_CWD=/home/elsewhere
[ "$RC" -eq 0 ] && ok || bad "checkout: outside protected dir should be ALLOWED (rc=$RC)"

run_hook guard-protected-checkout.sh \
  '{"tool_input":{"command":"git fetch origin"}}' \
  PROTECTED_DIRS=/tmp/protrepo GUARD_CWD=/tmp/protrepo
[ "$RC" -eq 0 ] && ok || bad "checkout: non-checkout command should be ALLOWED (rc=$RC)"

echo "== e2e: guard-worktree-bash.sh =="
run_hook guard-worktree-bash.sh \
  '{"tool_input":{"command":"cd repo && git worktree add /tmp/wt -b x"}}'
[ "$RC" -eq 2 ] && ok || bad "worktree: chained add outside .claude/worktrees should be DENIED (rc=$RC)"

run_hook guard-worktree-bash.sh \
  '{"tool_input":{"command":"cd repo && git worktree add .claude/worktrees/x -b x"}}'
[ "$RC" -eq 0 ] && ok || bad "worktree: add under .claude/worktrees should be ALLOWED (rc=$RC)"

echo "== e2e: notify-worktree-sessionstart.sh =="
# Advisory notice: fires only inside a protected root, silent everywhere else.
run_hook notify-worktree-sessionstart.sh '' PROTECTED_DIRS=/tmp/protrepo GUARD_CWD=/tmp/protrepo/src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("EnterWorktree")' >/dev/null 2>&1
then ok; else bad "sessionstart: should emit EnterWorktree notice in protected dir (rc=$RC out=$OUT)"; fi

run_hook notify-worktree-sessionstart.sh '' PROTECTED_DIRS=/tmp/protrepo GUARD_CWD=/home/elsewhere
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad "sessionstart: should stay silent outside protected dirs (out=$OUT)"; fi

run_hook notify-worktree-sessionstart.sh '' \
  PROTECTED_DIRS=/tmp/protrepo GUARD_CWD=/tmp/protrepo/.claude/worktrees/x
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad "sessionstart: should stay silent inside a worktree (out=$OUT)"; fi

run_hook notify-worktree-sessionstart.sh '' PROTECTED_DIRS= GUARD_CWD=/tmp/protrepo
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad "sessionstart: no protected_dirs configured = silent (out=$OUT)"; fi

echo "== e2e: guard-protected-branch.sh (temp repo on main) =="
tmp=$(mktemp -d)
git -C "$tmp" init -q -b main
git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name t
git -C "$tmp" commit -q --allow-empty -m init
(
  cd "$tmp" || exit 1
  OUT=$(printf '%s' '{"tool_input":{"command":"git fetch origin main --quiet && git commit -m x"}}' \
    | env PROTECTED_BRANCHES='^main$' REPO_FILTER='' bash "$HOOKS/guard-protected-branch.sh" 2>/dev/null)
  exit $?
)
[ "$?" -eq 2 ] && ok || bad "branch: chained commit on main should be DENIED"
(
  cd "$tmp" || exit 1
  printf '%s' '{"tool_input":{"command":"git status && echo hi"}}' \
    | env PROTECTED_BRANCHES='^main$' REPO_FILTER='' bash "$HOOKS/guard-protected-branch.sh" >/dev/null 2>&1
  exit $?
)
[ "$?" -eq 0 ] && ok || bad "branch: non-commit command on main should be ALLOWED"
rm -rf "$tmp"

echo
printf 'PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
