#!/usr/bin/env bash
# Tests for /review-pr in scripts/lib.sh — one PR per run, for a cloud scheduled
# task fired by a GitHub review request: argument forms, the PR from HEAD, the
# by-name request guard, the per-PR mode, the review state carried on GitHub
# (state comment + hydration), and finish's duplicate check. No framework — run:
#   bash plugins/fu-review-prs/test/review-pr.test.sh
#
# Hermetic: a throwaway HOME holds the state dir, and `gh`/`git` are stubbed on
# PATH, so nothing here touches the real ~/.claude/pr-review or hits GitHub.
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
has()    { if grep -qF -- "$2" <<<"$3"; then ok; else bad "$1 (missing <$2>)"; fi; }
has_no() { if grep -qF -- "$2" <<<"$3"; then bad "$1 (unexpected <$2>)"; else ok; fi; }

SANDBOX=""
new_sandbox() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$SANDBOX/bin"
  export GH_POST="$SANDBOX/gh-post.txt" GH_DEL="$SANDBOX/gh-del.txt"
  export REVIEWS="$SANDBOX/reviews.json"
  echo '[]' > "$REVIEWS"
  # gh stub. REST endpoints answer raw JSON and apply --jq with the real jq.
  #   REQUESTED  — logins requested by name on the PR (default "bot", us)
  #   HEAD_PRS   — open PRs whose head is the checkout's HEAD (default 7)
  #   $REVIEWS   — the PR's reviews, served for GET .../reviews?…
  cat >"$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
jqf="" prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$1 $2" in
  "api user") echo "bot"; exit 0 ;;
  "pr "*|"repo "*|"issue "*) echo "GraphQL is not available" >&2; exit 1 ;;
esac
[ "$1" = api ] || exit 0
case "$2" in
  */commits/*/pulls)
    printf '%s\n' "${HEAD_PRS-7}" \
      | jq -R 'select(length > 0) | {number: tonumber, state: "open", head: {sha: "localhead"}}' \
      | jq -s . | respond ;;
  */commits/*) echo "${HEAD_TREE:-cafef00d}" ;;
  */pulls/*/files*)
    printf '%s\n' "${PR_FILES-src/a.cs}" \
      | jq -R --argjson n "${FILE_LINES:-10}" \
          'select(length > 0) | {filename: ., additions: $n, deletions: 0}' \
      | jq -s . | respond ;;
  */pulls/*/reviews\?*) respond < "$REVIEWS" ;;
  */pulls/*/reviews)
    if [[ "$*" == *"--method POST"* ]]; then
      printf '%s\n' "$@" > "$GH_POST"; echo "2026-10-23T05:00:00Z"
    else
      respond < "$REVIEWS"
    fi ;;
  */pulls/*/requested_reviewers*) ;;
  */pulls/[0-9]*)
    printf '%s\n' "${REQUESTED-bot}" | jq -R 'select(length > 0) | {login: .}' | jq -s \
      --arg sha "${HEAD_SHA:-deadbeef}" \
      '{user: {login: "alice"}, state: "open", head: {sha: $sha}, title: "Some PR",
        requested_reviewers: .}' | respond ;;
  */compare/*) printf '%s\n' "${COMPARE_FILES-src/a.cs}" ;;
  */reactions/*) [[ "$*" == *"--method DELETE"* ]] && echo "$2" >> "$GH_DEL" ;;
  */reactions\?content=eyes*)
    echo '[{"id": 11, "user": {"login": "bot"}}]' | respond ;;
esac
exit 0
STUB
  cat >"$SANDBOX/bin/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "remote.origin.url" ] && { echo "https://github.com/acme/widgets.git"; exit 0; }; done
for a in "$@"; do [ "$a" = "--is-inside-work-tree" ] && exit 1; done
for a in "$@"; do [ "$a" = "HEAD" ] && { echo "localhead"; exit 0; }; done
for a in "$@"; do [ "$a" = "rev-parse" ] && { echo "/nonexistent/review-clone"; exit 0; }; done
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/git"
  export PATH="$SANDBOX/bin:$PATH"
  unset REQUESTED HEAD_PRS HEAD_SHA HEAD_TREE PR_FILES FILE_LINES COMPARE_FILES PR_REVIEW_REPO \
        PR_REVIEW_AUTO_APPROVE CLAUDE_PLUGIN_ROOT REVIEW_TASK_FILE
  STATE="$HOME/.claude/pr-review/state/acme-widgets"
}
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# one <args...>: run pr_review_one in a fresh shell, stdout to $SANDBOX/out.
one() {
  bash -c 'source "$1"; shift; pr_review_one "$@"' _ "$LIB" "$@" \
    > "$SANDBOX/out" 2> "$SANDBOX/err"
}
out()   { cat "$SANDBOX/out"; }
first() { head -n 1 "$SANDBOX/out"; }

# finish_with <findings-json> <started> [mode lines]: seed one dispatch of PR 7
# (pending at deadbeef/cafef00d, dispatched at <started>), then run finish.
finish_with() {
  bash -c '
    source "$1"
    printf "%s\n" "$2" > "$(pr_path findings 7)"
    record_write pending 7 deadbeef cafef00d "$3"
    echo low-risk > "$(pr_path gate 7)"
    [ -n "$4" ] && printf "%s\n" "$4" > "$(pr_path mode 7)"
    pr_review_finish 7
  ' _ "$LIB" "$1" "$2" "${3-single}" > "$SANDBOX/out" 2> "$SANDBOX/err"
}
posted_body()  { sed -n '/^body=/,/^--jq$/p' "$GH_POST" 2>/dev/null | sed '1s/^body=//;$d'; }
posted_event() { sed -n 's/^event=//p' "$GH_POST" 2>/dev/null; }
# The JSON inside the posted state comment.
posted_state() {
  posted_body | sed -nE 's/^<!-- fu-review-state:([A-Za-z0-9+\/=]+) -->$/\1/p' | base64 -d
}
# serve_review <login> <body> <submitted_at> <commit_id>: add a review to GET.
serve_review() {
  jq --arg u "$1" --arg b "$2" --arg at "$3" --arg c "$4" \
    '. + [{user: {login: $u}, body: $b, submitted_at: $at, commit_id: $c}]' \
    "$REVIEWS" > "$REVIEWS.new" && mv "$REVIEWS.new" "$REVIEWS"
}

echo "== argument forms: N, #N and a PR URL =="
new_sandbox
one 7
eq "bare number" "PROCEED 7 acme/widgets" "$(first)"
has "the Task prompt follows" "Review PR #7." "$(out)"
new_sandbox
one '#7'
eq "#number" "PROCEED 7 acme/widgets" "$(first)"
new_sandbox
one https://github.com/other/thing/pull/12/files
eq "URL sets PR and repo" "PROCEED 12 other/thing" "$(first)"
has "state under the URL's repo" "/state/other-thing/scope-12.txt" "$(out)"

echo "== --auto-approve is recorded per PR, not tick-wide =="
new_sandbox
one 7 --auto-approve
eq "mode file" "single
auto-approve" "$(cat "$STATE/mode-7" 2>/dev/null)"
eq "no tick-wide flag" "no" "$([ -e "$STATE/auto-approve" ] && echo yes || echo no)"
new_sandbox
one 7
eq "default mode" "single" "$(cat "$STATE/mode-7" 2>/dev/null)"

echo "== no PR argument: the open PR whose head is HEAD =="
new_sandbox
HEAD_PRS=9 one --auto-approve
eq "resolved from HEAD" "PROCEED 9 acme/widgets" "$(first)"
new_sandbox
HEAD_PRS="" one
eq "no PR at HEAD" "SKIP" "$(out | cut -d" " -f1)"
new_sandbox
HEAD_PRS=$'9\n10' one
eq "two PRs at HEAD" "SKIP" "$(out | cut -d" " -f1)"

echo "== guard: only a request to us by name =="
new_sandbox
REQUESTED="" one 7
eq "team-only request (we are not listed)" "SKIP" "$(out | cut -d" " -f1)"
eq "nothing left behind" "" "$(ls "$STATE" 2>/dev/null)"
new_sandbox
REQUESTED=carol one 7
eq "someone else requested" "SKIP" "$(out | cut -d" " -f1)"
new_sandbox
REQUESTED=$'carol\nbot' one 7
eq "us among others" "PROCEED 7 acme/widgets" "$(first)"

echo "== a SKIP names the PR and why, on its one line =="
# A cloud run's log file dies with its sandbox: this line is the only record.
new_sandbox
HEAD_PRS="" one
eq "no PR at HEAD" "SKIP — HEAD localhead is the head of 0 open PR(s) — need exactly one" "$(out)"
new_sandbox
REQUESTED=carol one 7
eq "not requested" "SKIP — PR #7: review not requested from bot by name" "$(out)"
new_sandbox
PR_FILES="" one 7
has "pre-flight's own reason" "SKIP — PR #7: changes no files" "$(out)"
eq "still one line" "1" "$(out | wc -l | tr -d ' ')"

echo "== a pre-flight SKIP clears the mode =="
new_sandbox
PR_FILES="" one 7 --auto-approve
eq "empty PR skips" "SKIP" "$(out | cut -d" " -f1)"
eq "no mode left for a later loop tick" "no" "$([ -e "$STATE/mode-7" ] && echo yes || echo no)"

echo "== the per-PR mode wins over the loop's flag =="
new_sandbox
mkdir -p "$STATE"; : > "$STATE/auto-approve"
finish_with '{"findings":[]}' 2026-10-23T04:00:00Z single
eq "single run without --auto-approve comments" "COMMENT" "$(posted_event)"
new_sandbox
finish_with '{"findings":[]}' 2026-10-23T04:00:00Z $'single\nauto-approve'
eq "single run with --auto-approve approves" "APPROVE" "$(posted_event)"
eq "status" "POSTED APPROVE" "$(out)"
eq "mode cleared after finish" "no" "$([ -e "$STATE/mode-7" ] && echo yes || echo no)"

echo "== no heartbeat badge on a single run =="
new_sandbox
mkdir -p "$HOME/.claude/fu-tools"
echo '{"review-prs":{"heartbeat_url":"https://hb.example","heartbeat_token":"t","heartbeat_footer":true}}' \
  > "$HOME/.claude/fu-tools/config.json"
finish_with '{"findings":[]}' 2026-10-23T04:00:00Z single
has_no "no badge" "badge/acme/widgets.svg" "$(posted_body)"
new_sandbox
mkdir -p "$HOME/.claude/fu-tools"
echo '{"review-prs":{"heartbeat_url":"https://hb.example","heartbeat_token":"t","heartbeat_footer":true}}' \
  > "$HOME/.claude/fu-tools/config.json"
finish_with '{"findings":[]}' 2026-10-23T04:00:00Z ""
has "the loop keeps its badge" "badge/acme/widgets.svg" "$(posted_body)"

echo "== finish carries the review state in a hidden comment =="
new_sandbox
finish_with '{"findings":[{"severity":"BLOCKER","text":"Boom","where":"a.cs:1"}],
  "prior":[{"status":"RESOLVED","severity":"NIT","text":"Old"},
           {"status":"STILL OPEN","severity":"NIT","text":"Still"}]}' 2026-10-23T04:00:00Z
eq "the comment is the body's last line" "1" \
  "$(posted_body | tail -n 1 | grep -c '^<!-- fu-review-state:[A-Za-z0-9+/=]* -->$')"
eq "commit, tree and the carried findings (RESOLVED dropped)" \
  '{"v":1,"commit":"deadbeef","tree":"cafef00d","carried":{"findings":[{"severity":"BLOCKER","text":"Boom","where":"a.cs:1"},{"severity":"NIT","text":"Still"}]}}' \
  "$(posted_state | jq -c .)"
eq "the same carried findings on disk" "$(posted_state | jq -c .carried)" \
  "$(jq -c . "$STATE/last-findings-7.json")"

echo "== carried findings that would overflow the body are left out =="
new_sandbox
big=$(head -c 40000 /dev/zero | tr '\0' x)
finish_with "{\"findings\":[{\"severity\":\"NIT\",\"text\":\"$big\"}]}" 2026-10-23T04:00:00Z
eq "commit and tree only" '{"v":1,"commit":"deadbeef","tree":"cafef00d"}' "$(posted_state | jq -c .)"
eq "posted anyway" "POSTED COMMENT" "$(out)"

echo "== pre-flight restores the state from our latest review =="
new_sandbox
state=$(jq -cn '{v:1, commit:"0ldc0mm1t", tree:"01dtree",
  carried:{findings:[{severity:"BLOCKER",text:"Boom",where:"a.cs:1"}]}}' | base64 | tr -d '\n')
serve_review bot $'<!-- claude-pr-review -->\nold text\n<!-- fu-review-state:'"$state"' -->' \
  2026-10-20T00:00:00Z 0ldc0mm1t
one 7
eq "reviewed record restored" "commit=0ldc0mm1t
tree=01dtree
reviewed_at=2026-10-20T00:00:00Z" "$(cat "$STATE/last-reviewed-7" 2>/dev/null)"
eq "DELTA from the restored commit" "MODE=DELTA" "$(grep '^MODE=' "$STATE/scope-7.txt")"
eq "structured priors for the sub-agent" \
  '{"findings":[{"severity":"BLOCKER","text":"Boom","where":"a.cs:1"}]}' \
  "$(jq -c . "$STATE/prior-7.json")"

echo "== another user's marked review cannot plant state =="
new_sandbox
serve_review mallory $'<!-- claude-pr-review -->\n<!-- fu-review-state:'"$state"' -->' \
  2026-10-21T00:00:00Z 0ldc0mm1t
one 7
eq "nothing restored" "no" "$([ -e "$STATE/last-reviewed-7" ] && echo yes || echo no)"
eq "FULL review" "MODE=FULL" "$(grep '^MODE=' "$STATE/scope-7.txt")"

echo "== only the latest review counts: one without state restores nothing =="
new_sandbox
serve_review bot $'<!-- claude-pr-review -->\n<!-- fu-review-state:'"$state"' -->' \
  2026-10-20T00:00:00Z 0ldc0mm1t
serve_review bot $'<!-- claude-pr-review -->\nposted before the state comment' \
  2026-10-21T00:00:00Z newer
one 7
eq "nothing restored" "no" "$([ -e "$STATE/last-reviewed-7" ] && echo yes || echo no)"
has "its text still rides along as legacy_body" "posted before the state comment" \
  "$(jq -r '.legacy_body // ""' "$STATE/prior-7.json")"

echo "== the legacy body never shows the state comment =="
new_sandbox
serve_review bot $'<!-- claude-pr-review -->\nsome text\n<!-- fu-review-state:bm90IGpzb24= -->' \
  2026-10-21T00:00:00Z newer
one 7
has "the text is there" "some text" "$(jq -r '.legacy_body // ""' "$STATE/prior-7.json")"
has_no "the comment is not" "fu-review-state" "$(jq -r '.legacy_body // ""' "$STATE/prior-7.json")"

echo "== duplicate: another run posted on this head after we were dispatched =="
new_sandbox
serve_review bot '<!-- claude-pr-review -->' 2026-10-23T04:30:00Z deadbeef
finish_with '{"findings":[]}' 2026-10-23T04:00:00Z
eq "status" "DUPLICATE" "$(out)"
eq "not posted" "no" "$([ -e "$GH_POST" ] && echo yes || echo no)"
eq "our eyes cleared" "repos/acme/widgets/issues/7/reactions/11" "$(cat "$GH_DEL" 2>/dev/null)"
eq "transients cleared" "no" "$([ -e "$STATE/pending-7" ] && echo yes || echo no)"

echo "== not a duplicate: before dispatch, another head, or someone else's =="
new_sandbox
serve_review bot '<!-- claude-pr-review -->' 2026-10-23T03:00:00Z deadbeef
serve_review bot '<!-- claude-pr-review -->' 2026-10-23T04:30:00Z otherhead
serve_review carol '<!-- claude-pr-review -->' 2026-10-23T04:30:00Z deadbeef
finish_with '{"findings":[]}' 2026-10-23T04:00:00Z
eq "posts" "POSTED COMMENT" "$(out)"

echo "== stdout carries tokens only =="
new_sandbox
one 7
eq "stderr is empty" "" "$(cat "$SANDBOX/err")"

# ── --routine: the cloud routine's self-contained review ──────────────────────
five_files=$'src/a.cs\nsrc/b.cs\nsrc/c.cs\nsrc/d.cs\nsrc/e.cs'
headers() { grep '^--- ' "$SANDBOX/out"; }

echo "== routine: a small scope gets one reviewer running every angle group =="
new_sandbox
one 7 --routine
eq "token line" "SINGLE 7 acme/widgets" "$(first)"
eq "one reviewer block" "--- reviewer all ---" "$(headers)"
has "the reviewer brief" "$ROOT/routine-reviewer.md and follow it exactly. Review PR #7, angle group: all." "$(out)"
has "it re-checks the priors" "  PRIOR_FILE = $STATE/prior-7.json" "$(out)"
has "it writes the findings file itself" "  OUTPUT_FILE = $STATE/findings-7.json" "$(out)"
has "the review worktree" "  REVIEW_DIR = $HOME/.claude/pr-review/worktrees/acme-widgets" "$(out)"
eq "mode" "single
routine" "$(cat "$STATE/mode-7" 2>/dev/null)"
eq "stderr is empty" "" "$(cat "$SANDBOX/err")"

echo "== routine: the SINGLE threshold is 5 files and 200 lines, inclusive =="
new_sandbox
PR_FILES=$five_files FILE_LINES=40 one 7 --routine
eq "5 files, 200 lines" "SINGLE 7 acme/widgets" "$(first)"
new_sandbox
PR_FILES=$'src/a.cs\nsrc/b.cs\nsrc/c.cs\nsrc/d.cs\nsrc/e.cs\nsrc/f.cs' FILE_LINES=1 one 7 --routine
eq "6 files" "FANOUT 7 acme/widgets" "$(first)"
new_sandbox
FILE_LINES=201 one 7 --routine
eq "201 lines in one file" "FANOUT 7 acme/widgets" "$(first)"

echo "== routine: DELTA counts only the files in scope =="
new_sandbox
state=$(jq -cn '{v:1, commit:"0ldc0mm1t", tree:"01dtree"}' | base64 | tr -d '\n')
serve_review bot $'<!-- claude-pr-review -->\n<!-- fu-review-state:'"$state"' -->' \
  2026-10-20T00:00:00Z 0ldc0mm1t
PR_FILES=$'src/a.cs\nsrc/b.cs\nsrc/c.cs\nsrc/d.cs\nsrc/e.cs\nsrc/f.cs' COMPARE_FILES=src/a.cs \
  FILE_LINES=50 one 7 --routine
eq "one file of six in scope" "SINGLE 7 acme/widgets" "$(first)"

echo "== routine: a large scope fans out to four finders and a merger =="
new_sandbox
FILE_LINES=500 one 7 --routine
eq "headers, in dispatch order" "--- reviewer diff ---
--- reviewer trace ---
--- reviewer cleanup ---
--- reviewer intent ---
--- merger ---" "$(headers)"
has "a reviewer writes its part" "  OUTPUT_FILE = $STATE/findings-7.trace.json" "$(out)"
eq "only the merger re-checks priors" "1" "$(grep -c 'PRIOR_FILE' "$SANDBOX/out")"
has "the merger brief" "$ROOT/routine-merger.md and follow it exactly. Merge the reviews of PR #7." "$(out)"
has "the merger reads every part" "  PART_FILE_INTENT = $STATE/findings-7.intent.json" "$(out)"
has "the merger writes the findings file" "  FINDINGS_FILE = $STATE/findings-7.json" "$(out)"
eq "mode" "single
routine
fanout" "$(cat "$STATE/mode-7" 2>/dev/null)"
eq "both briefs ship" "yes" \
  "$([ -f "$ROOT/routine-reviewer.md" ] && [ -f "$ROOT/routine-merger.md" ] && echo yes)"

echo "== routine: the guard and pre-flight SKIPs are /review-pr's =="
new_sandbox
REQUESTED="" one 7 --routine
eq "team-only request" "SKIP" "$(out | cut -d" " -f1)"
eq "nothing left behind" "" "$(ls "$STATE" 2>/dev/null)"
new_sandbox
PR_FILES="" one 7 --routine
eq "empty PR" "SKIP" "$(out | cut -d" " -f1)"

# finish_parts <dims…>: seed a FANOUT dispatch of PR 7 with a merged findings
# file and a valid part for each named dimension, then run finish.
finish_parts() {
  bash -c '
    source "$1"; shift
    for d in "$@"; do echo "{\"findings\":[]}" > "$(pr_path "part_$d" 7)"; done
    echo "{\"findings\":[]}" > "$(pr_path findings 7)"
    record_write pending 7 deadbeef cafef00d 2026-10-23T04:00:00Z
    printf "single\nroutine\nfanout\n" > "$(pr_path mode 7)"
    pr_review_finish 7
  ' _ "$LIB" "$@" > "$SANDBOX/out" 2> "$SANDBOX/err"
}

echo "== routine: a FANOUT missing any reviewer's findings posts nothing =="
new_sandbox
finish_parts diff trace cleanup
eq "status" "NO_FINDINGS" "$(out)"
eq "not posted" "no" "$([ -e "$GH_POST" ] && echo yes || echo no)"
eq "parts cleared" "" "$(ls "$STATE"/findings-7.* 2>/dev/null)"
new_sandbox
bash -c 'source "$1"; echo "{\"findings\":[{\"severity\":\"HIGH\",\"text\":\"x\"}]}" > "$(pr_path part_intent 7)"' _ "$LIB"
finish_parts diff trace cleanup
eq "an invalid part counts as missing" "NO_FINDINGS" "$(out)"

echo "== routine: a complete FANOUT posts, with the routine's footer =="
new_sandbox
finish_parts diff trace cleanup intent
eq "status" "POSTED COMMENT" "$(out)"
has "footer" "*Automated review by a Claude Code routine*" "$(posted_body)"
has_no "not /code-review's footer" "via /code-review" "$(posted_body)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
