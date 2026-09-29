#!/usr/bin/env bash
# Tests for structured findings in scripts/lib.sh — the sub-agent writes
# findings-<pr>.json, and bash owns everything derived from it: the posted body,
# the verdict, the blocker count, strict validation, and the findings carried to
# the next DELTA review (plus the legacy fallback for reviews posted before
# findings were saved). Exercised through pr_review_finish and
# pr_review_preflight. No framework — run:
#   bash plugins/fu-review-prs/test/findings.test.sh
#
# Hermetic: a throwaway HOME holds the state dir and the fu-tools config, and
# `gh`/`git`/`curl` are stubbed on PATH — nothing here reaches GitHub or Teams.
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
  mkdir -p "$HOME/.claude/fu-tools" "$SANDBOX/bin"
  export GH_POST="$SANDBOX/gh-post.txt" CURL_PAYLOAD="$SANDBOX/payload.json"
  # gh stub. The real gh applies --jq itself, so the stub answers post-jq values.
  #   REVIEWS       — the raw reviews list a GET returns (no --jq: lib.sh pipes it to jq)
  #   GH_POST_FAILS — non-empty makes the review POST fail
  #   OPEN_PRS      — the `pr list` answer
  cat >"$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/widgets"; exit 0 ;;
  "api user")  echo "bot"; exit 0 ;;
  "pr list")   printf '%s\n' "${OPEN_PRS-7}"; exit 0 ;;
  "pr view")
    if [[ "$*" == *"author,state"* ]]; then echo '{"author":{"login":"alice"},"state":"OPEN"}'
    elif [[ "$*" == *"headRefOid"* ]]; then echo "deadbeef"
    else echo "Some PR"; fi
    exit 0 ;;
esac
if [ "$1" = "api" ] && [[ "$2" == *"/commits/"* ]]; then echo cafef00d; exit 0; fi
if [ "$1" = "api" ] && [[ "$2" == *"/pulls/"*"/files" ]]; then echo src/a.cs; exit 0; fi
if [ "$1" = "api" ] && [[ "$2" == *"/pulls/"*"/reviews" ]]; then
  if [[ "$*" == *"--method POST"* ]]; then
    [ -n "${GH_POST_FAILS:-}" ] && exit 1
    printf '%s\n' "$@" > "$GH_POST"
    printf '2026-09-28T10:00:00Z'
  else
    printf '%s\n' "${REVIEWS-[]}"
  fi
  exit 0
fi
exit 0
STUB
  cat >"$SANDBOX/bin/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--is-inside-work-tree" ] && exit 1; done
for a in "$@"; do [ "$a" = "rev-parse" ] && { echo "/nonexistent/review-clone"; exit 0; }; done
exit 0
STUB
  # curl stub: keep the notification's JSON body so a case can read the count.
  cat >"$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  [ "$prev" = "--data-binary" ] && printf '%s' "$a" > "$CURL_PAYLOAD"
  prev="$a"
done
printf 202
STUB
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/git" "$SANDBOX/bin/curl"
  export PATH="$SANDBOX/bin:$PATH"
  unset PR_REVIEW_AUTO_APPROVE REVIEWS GH_POST_FAILS OPEN_PRS CLAUDE_PLUGIN_ROOT REVIEW_TASK_FILE
  jq -n '{"review-prs": {notify: ["teams"], teams_webhook: "https://hook.example/x"}}' \
    > "$HOME/.claude/fu-tools/config.json"
  STATE="$HOME/.claude/pr-review/state/acme-widgets"
  LOG="$HOME/.claude/pr-review/review-acme-widgets.log"
}
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Source lib.sh in a fresh shell (it computes its paths at source time) and run a
# snippet; cwd is the sandbox so fu-config.sh resolves no project config.
# lib <shell-snippet>
lib() { ( cd "$SANDBOX" && bash -c 'source "$1"; eval "$2"' _ "$LIB" "$1" ) 2>/dev/null; }

# Seed a dispatched PR 7 whose sub-agent wrote <json>, then finish it.
# finish <json> [set_mode-args]
finish() {
  mkdir -p "$STATE"
  printf '%s\n' "$1" > "$STATE/findings-7.json"
  lib "record_write pending 7 deadbeef cafef00d; pr_review_set_mode ${2:-}; pr_review_finish 7"
}
# The body field of the posted review, and its event.
posted_body()  { sed -n '/^body=/,/^--jq$/p' "$GH_POST" 2>/dev/null | sed '1s/^body=//;$d'; }
posted_event() { sed -n 's/^event=//p' "$GH_POST" 2>/dev/null; }
posted()       { [ -e "$GH_POST" ] && echo yes || echo no; }
notified()     { jq -r '.summary' "$CURL_PAYLOAD" 2>/dev/null; }

echo "== current findings render as a numbered list, in the posted body =="
new_sandbox
finish '{"findings":[
  {"severity":"BLOCKER","text":"Null deref on empty cart","where":"src/Cart.cs:42"},
  {"severity":"NIT","text":"Typo in comment"}]}'
eq "posted body" '<!-- claude-pr-review -->
### Code review — PR #7
Found 2 issues:
1. [BLOCKER] Null deref on empty cart — `src/Cart.cs:42`
2. [NIT] Typo in comment

---
*Automated review by Claude Code via /code-review*' "$(posted_body)"
eq "a blocker posts COMMENT" "COMMENT" "$(posted_event)"
has "notified with the count" "1 blocker(s)" "$(notified)"
cleanup

echo "== DELTA: the prior block comes first, status before the original tag =="
new_sandbox
finish '{"findings":[{"severity":"NIT","text":"New nit","where":"b.cs:2"}],
  "prior":[
  {"status":"RESOLVED","severity":"BLOCKER","text":"Unconditional write","where":"a.cs:266"},
  {"status":"STILL OPEN","severity":"NIT","text":"Rename x"}]}'
eq "posted body" '<!-- claude-pr-review -->
### Code review — PR #7
Prior findings:
1. RESOLVED — [BLOCKER] Unconditional write — `a.cs:266`
2. STILL OPEN — [NIT] Rename x

Found 1 issues:
1. [NIT] New nit — `b.cs:2`

---
*Automated review by Claude Code via /code-review*
*No blockers found. Posted as a comment, not an approval — auto-approve is off.*' "$(posted_body)"
cleanup

echo "== a RESOLVED prior blocker is not a current blocker =="
new_sandbox
finish '{"findings":[],"prior":[{"status":"RESOLVED","severity":"BLOCKER","text":"Fixed"}]}' --auto-approve
eq "verdict APPROVE" "APPROVE" "$(posted_event)"
has "notified clean" "no blockers" "$(notified)"
cleanup

echo "== STILL OPEN and REINTRODUCED prior blockers are current blockers =="
new_sandbox
finish '{"findings":[{"severity":"BLOCKER","text":"New"}],"prior":[
  {"status":"STILL OPEN","severity":"BLOCKER","text":"Open"},
  {"status":"REINTRODUCED","severity":"BLOCKER","text":"Back"},
  {"status":"RESOLVED","severity":"BLOCKER","text":"Gone"},
  {"status":"STILL OPEN","severity":"NIT","text":"Just a nit"}]}' --auto-approve
eq "verdict COMMENT, even with auto-approve" "COMMENT" "$(posted_event)"
has "three current blockers" "3 blocker(s)" "$(notified)"
cleanup

echo "== zero findings: 'Found 0 issues:', and APPROVE with auto-approve =="
new_sandbox
finish '{"findings":[]}' --auto-approve
eq "posted body" '<!-- claude-pr-review -->
### Code review — PR #7
Found 0 issues:

---
*Automated review by Claude Code via /code-review*' "$(posted_body)"
eq "verdict APPROVE" "APPROVE" "$(posted_event)"
cleanup

echo "== line breaks in text and where become spaces, ends are trimmed, the rest is verbatim =="
new_sandbox
finish '{"findings":[{"severity":"NIT","text":"Two\nlines & <b>markup</b> `code`","where":"a.cs:1\r\n"}]}'
has "flattened, verbatim otherwise" '1. [NIT] Two lines & <b>markup</b> `code` — `a.cs:1`' "$(posted_body)"
cleanup

echo "== a blank where is no where: no empty location, nothing carried =="
new_sandbox
finish '{"findings":[{"severity":"NIT","text":"a","where":"  \n "}]}'
eq "no location rendered" "1. [NIT] a" "$(posted_body | grep '^1\. ')"
eq "carried without where" '{"findings":[{"severity":"NIT","text":"a"}]}' "$(jq -c . "$STATE/last-findings-7.json")"
cleanup

# Strict: any violation rejects the whole file — nothing posts, no state is
# saved, and the PR retries next tick with a "no review" notification.
# rejected <desc> <json> <logged-reason>
rejected() {
  new_sandbox
  finish "$2"
  eq "$1: nothing posted" "no" "$(posted)"
  eq "$1: no state saved" "absent" "$([ -e "$STATE/last-reviewed-7" ] && echo present || echo absent)"
  has "$1: reason logged" "$3" "$(cat "$LOG")"
  has "$1: notified" "no review body produced" "$(notified)"
  cleanup
}
echo "== invalid findings are rejected whole =="
rejected "not JSON"         '{"findings":['                                   "not valid JSON"
rejected "two objects"      '{"findings":[]} {"findings":[]}'                "expected one JSON object"
rejected "no findings key"  '{"prior":[]}'                                    "findings must be an array"
rejected "bad severity"     '{"findings":[{"severity":"MAJOR","text":"x"}]}'  "findings[0]: severity must be BLOCKER or NIT"
rejected "lowercase sev"    '{"findings":[{"severity":"blocker","text":"x"}]}' "severity must be BLOCKER or NIT"
rejected "blank text"       '{"findings":[{"severity":"NIT","text":"  "}]}'   "findings[0]: text must be a non-empty string"
rejected "numeric where"    '{"findings":[{"severity":"NIT","text":"x","where":42}]}' "where must be a string"
rejected "bad status"       '{"findings":[],"prior":[{"status":"FIXED","severity":"NIT","text":"x"}]}' \
  "prior[0]: status must be RESOLVED, STILL OPEN or REINTRODUCED"
rejected "one bad of two"   '{"findings":[{"severity":"NIT","text":"ok"},{"severity":"NIT"}]}' \
  "findings[1]: text must be a non-empty string"

echo "== no findings file at all: the same retry path =="
new_sandbox
eq "status token" "NO_FINDINGS" "$(lib 'record_write pending 7 deadbeef cafef00d; pr_review_finish 7')"
eq "nothing posted" "no" "$(posted)"
has "reason logged" "no findings file" "$(cat "$LOG")"
has "notified" "no review body produced" "$(notified)"
cleanup

# --- carried to the next DELTA ------------------------------------------------
preflight() { lib 'pr_review_preflight 7 review_re_requested >/dev/null'; }
prior()     { jq -c . "$STATE/prior-7.json" 2>/dev/null; }

echo "== a posted review carries the live findings; RESOLVED ones drop =="
new_sandbox
finish '{"findings":[{"severity":"NIT","text":"New","where":"b.cs:2"}],"prior":[
  {"status":"RESOLVED","severity":"BLOCKER","text":"Gone"},
  {"status":"STILL OPEN","severity":"BLOCKER","text":"Open","where":"a.cs:1"},
  {"status":"REINTRODUCED","severity":"NIT","text":"Back"}]}'
preflight
eq "next pre-flight's prior file" \
  '{"findings":[{"severity":"NIT","text":"New","where":"b.cs:2"},{"severity":"BLOCKER","text":"Open","where":"a.cs:1"},{"severity":"NIT","text":"Back"}]}' \
  "$(prior)"
cleanup

echo "== a failed post carries nothing =="
new_sandbox
lib 'record_write reviewed 7 0ld 01d'
printf '{"findings":[{"severity":"NIT","text":"Earlier"}]}' > "$STATE/last-findings-7.json"
GH_POST_FAILS=1 finish '{"findings":[{"severity":"NIT","text":"Unposted"}]}'
eq "earlier findings still carried" '{"findings":[{"severity":"NIT","text":"Earlier"}]}' \
  "$(jq -c . "$STATE/last-findings-7.json")"
cleanup

echo "== no carried findings and no prior review: an empty prior file =="
new_sandbox
preflight
eq "prior file" '{"findings":[]}' "$(prior)"
cleanup

echo "== a review posted before findings were saved: its text, as legacy_body =="
new_sandbox
export REVIEWS='[{"submitted_at":"2026-01-01T00:00:00Z","body":"<!-- claude-pr-review -->\n### Code review — PR #7\nFound 1 issues:\n1. [NIT] Old — a.cs:1\n\n---\n*Automated review by Claude Code via /code-review*"},
  {"submitted_at":"2026-01-02T00:00:00Z","body":"LGTM from a human"}]'
preflight
eq "legacy prior file" \
  '{"findings":[],"legacy_body":"\n### Code review — PR #7\nFound 1 issues:\n1. [NIT] Old — a.cs:1\n\n---"}' \
  "$(prior)"
cleanup

echo "== carried findings win over the GitHub lookup =="
new_sandbox
export REVIEWS='[{"submitted_at":"2026-01-01T00:00:00Z","body":"<!-- claude-pr-review -->\nold prose"}]'
mkdir -p "$STATE"
printf '{"findings":[{"severity":"NIT","text":"Carried"}]}' > "$STATE/last-findings-7.json"
preflight
eq "prior file" '{"findings":[{"severity":"NIT","text":"Carried"}]}' "$(prior)"
cleanup

echo "== purge: a closed PR's carried findings go with its record =="
new_sandbox
lib 'record_write reviewed 7 a b; record_write reviewed 8 c d'
echo '{"findings":[]}' > "$STATE/last-findings-7.json"
echo '{"findings":[]}' > "$STATE/last-findings-8.json"
OPEN_PRS=8 lib 'pr_review_purge_stale'
eq "only the open PR's state is left" $'last-findings-8.json\nlast-reviewed-8' "$(ls "$STATE")"
cleanup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
