#!/usr/bin/env bash
# Tests for what lets the plugin run in a Claude Code cloud session:
#   - the repo comes from the origin URL, never `gh repo view` (GraphQL);
#   - no GraphQL-backed gh command remains in lib.sh;
#   - detection reads requested_reviewers from the REST pulls list;
#   - a failed open-PR listing never purges review records;
#   - reviews run in a separate worktree, and the session's own checkout —
#     its branch, its uncommitted work, its other branches — is never touched.
# No framework — run:
#   bash plugins/fu-review-prs/test/cloud-session.test.sh
#
# Hermetic: a throwaway HOME holds the state dir, gh is stubbed on PATH, and the
# worktree cases run real git against a local bare "origin".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/scripts/lib.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

eq() { # eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1
    expected: <$2>
    actual:   <$3>"; fi
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

SANDBOX=""
new_sandbox() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$SANDBOX/bin"
  # gh stub. PULLS is the raw REST open-PR list; --jq is applied with the real
  # jq, as gh does. Every call is logged to GH_LOG.
  export GH_LOG="$SANDBOX/gh-calls.txt"
  cat >"$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
jqf="" prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$1 $2" in
  "api user") echo "bot"; exit 0 ;;
  "pr "*|"repo "*|"issue "*) echo "GraphQL is not available" >&2; exit 1 ;;
esac
if [ "$1" = "api" ] && [[ "$2" == *"/pulls?state=open"* ]]; then
  [ -n "${PULLS_FAIL:-}" ] && exit 1
  printf '%s\n' "${PULLS-[]}" | respond
  exit 0
fi
if [ "$1" = "api" ] && [[ "$2" == *"/reviews" ]]; then echo '[]'; exit 0; fi
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
  export PATH="$SANDBOX/bin:$PATH"
  unset PULLS PULLS_FAIL PR_REVIEW_REPO
}
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# lib <dir> <snippet>: source lib.sh from <dir> in a fresh shell, run <snippet>.
lib() { (cd "$1" && bash -c 'source "$1"; eval "$2"' _ "$LIB" "$2"); }

# A local bare origin with main, a PR head at refs/pull/7/head, and a clone of
# it standing in for the session's checkout. Sets ORIGIN, SRC, MAIN_SHA, PR_SHA.
make_repos() {
  local seed="$SANDBOX/seed"
  ORIGIN="$SANDBOX/origin.git" SRC="$SANDBOX/session"
  git init -q -b main "$seed"
  echo base > "$seed/base.txt"
  git -C "$seed" add . && git -C "$seed" commit -qm base
  git init -q --bare -b main "$ORIGIN"
  git -C "$seed" push -q "$ORIGIN" main
  git -C "$seed" checkout -q -b pr
  echo added > "$seed/pr-only.txt"
  git -C "$seed" add . && git -C "$seed" commit -qm pr
  git -C "$seed" push -q "$ORIGIN" pr:refs/pull/7/head
  MAIN_SHA=$(git -C "$ORIGIN" rev-parse main)
  PR_SHA=$(git -C "$ORIGIN" rev-parse refs/pull/7/head)
  git clone -q "$ORIGIN" "$SRC"
  git -C "$SRC" remote set-url origin "https://github.com/acme/widgets.git"
  git -C "$SRC" config "url.$ORIGIN.insteadOf" "https://github.com/acme/widgets.git"
}

echo "== the repo comes from the origin URL =="
new_sandbox
for url in https://github.com/acme/widgets https://github.com/acme/widgets.git \
           git@github.com:acme/widgets.git http://proxy@127.0.0.1:9/git/acme/widgets \
           ssh://git@github.com/acme/widgets.git/; do
  git init -q "$SANDBOX/r" && git -C "$SANDBOX/r" remote add origin "$url"
  eq "REPO from $url" "acme/widgets" "$(lib "$SANDBOX/r" 'echo "$REPO"')"
  rm -rf "$SANDBOX/r"
done
git init -q "$SANDBOX/r" && git -C "$SANDBOX/r" remote add origin https://github.com/acme/widgets
eq "PR_REVIEW_REPO wins" "other/repo" "$(PR_REVIEW_REPO=other/repo lib "$SANDBOX/r" 'echo "$REPO"')"
eq "no gh call to find the repo" "absent" "$([ -e "$GH_LOG" ] && echo present || echo absent)"
cleanup

echo "== lib.sh calls no GraphQL-backed gh command =="
eq "no gh pr/repo/issue/search outside comments" "" \
  "$(grep -nE '^[^#]*\bgh (pr|repo|issue|search)\b' "$LIB")"

echo "== detection queues only PRs that request review from us, by login =="
new_sandbox
git init -q "$SANDBOX/r" && git -C "$SANDBOX/r" remote add origin https://github.com/acme/widgets
export PULLS='[
  {"number": 5, "requested_reviewers": [{"login": "bot"}]},
  {"number": 6, "requested_reviewers": [{"login": "someone"}]},
  {"number": 8, "requested_reviewers": []},
  {"number": 9, "requested_reviewers": [{"login": "someone"}, {"login": "bot"}]}]'
eq "queued" "5 review_requested
9 review_requested" "$(lib "$SANDBOX/r" detect_queued_prs)"
cleanup

echo "== a failed open-PR listing keeps every review record =="
new_sandbox
git init -q "$SANDBOX/r" && git -C "$SANDBOX/r" remote add origin https://github.com/acme/widgets
STATE="$HOME/.claude/pr-review/state/acme-widgets"
mkdir -p "$STATE"
printf 'commit=c\ntree=t\n' > "$STATE/last-reviewed-7"
PULLS_FAIL=1 lib "$SANDBOX/r" pr_review_purge_stale
eq "record kept" "present" "$([ -e "$STATE/last-reviewed-7" ] && echo present || echo absent)"
PULLS='[{"number": 8, "requested_reviewers": []}]' lib "$SANDBOX/r" pr_review_purge_stale
eq "record of a closed PR purged once listing works" "absent" \
  "$([ -e "$STATE/last-reviewed-7" ] && echo present || echo absent)"
cleanup

echo "== the review worktree follows main and the PR head =="
new_sandbox
make_repos
WT="$HOME/.claude/pr-review/worktrees/acme-widgets"
lib "$SRC" pr_review_reset_tree
eq "worktree created at main" "$MAIN_SHA" "$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
eq "worktree is detached" "HEAD" "$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
lib "$SRC" "pr_review_checkout_head 7 $PR_SHA"
eq "worktree at the PR head" "$PR_SHA" "$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
eq "the PR's file is readable" "added" "$(cat "$WT/pr-only.txt" 2>/dev/null)"
echo stray > "$WT/stray.txt"
lib "$SRC" pr_review_reset_tree
eq "back at main" "$MAIN_SHA" "$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
eq "the PR's file is gone" "absent" "$([ -e "$WT/pr-only.txt" ] && echo present || echo absent)"
eq "untracked files are cleaned" "absent" "$([ -e "$WT/stray.txt" ] && echo present || echo absent)"
rm -rf "$WT"
lib "$SRC" pr_review_reset_tree
eq "a deleted worktree is recreated" "$MAIN_SHA" "$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
cleanup

echo "== the session's own checkout is never touched =="
new_sandbox
make_repos
git -C "$SRC" checkout -q -b feature
echo work > "$SRC/committed.txt"
git -C "$SRC" add . && git -C "$SRC" commit -qm work
git -C "$SRC" branch keepme
echo dirty >> "$SRC/base.txt"
echo untracked > "$SRC/untracked.txt"
before_head=$(git -C "$SRC" rev-parse HEAD)
lib "$SRC" "pr_review_reset_tree; pr_review_checkout_head 7 $PR_SHA; pr_review_reset_tree"
eq "still on its branch" "feature" "$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
eq "HEAD unchanged" "$before_head" "$(git -C "$SRC" rev-parse HEAD)"
eq "uncommitted edit kept" "base
dirty" "$(cat "$SRC/base.txt")"
eq "untracked file kept" "untracked" "$(cat "$SRC/untracked.txt" 2>/dev/null)"
eq "every branch kept" "feature
keepme
main" "$(git -C "$SRC" for-each-ref --format='%(refname:short)' refs/heads/ | sort)"
cleanup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
