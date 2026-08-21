#!/usr/bin/env bash
# Tests for the notification hook in scripts/lib.sh — opt-in channels, message
# content, and the rule that the webhook URL never reaches the log. No framework:
#   bash plugins/fu-review-prs/test/notify.test.sh
#
# Hermetic: a throwaway HOME holds both the fu-tools config and the state dir,
# and `gh`/`git`/`curl` are stubbed on PATH — nothing here reaches GitHub or Teams.
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

HOOK="https://prod-99.example.logic.azure.com/workflows/abc/triggers/manual/paths/invoke?sig=SUPERSECRETSIG"

SANDBOX=""
# curl_code lets a case simulate a webhook that rejects the post.
new_sandbox() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME/.claude/fu-tools" "$SANDBOX/bin"
  export CURL_LOG="$SANDBOX/curl.txt" CURL_CODE="${1:-202}"
  cat >"$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/widgets"; exit 0 ;;
  "pr view")   printf '%s\n' "${PR_TITLE-Fix null deref in OrderService}"; exit 0 ;;
esac
[ "${GH_POST_FAILS:-0}" = "1" ] && exit 1
exit 0
STUB
  cat >"$SANDBOX/bin/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--is-inside-work-tree" ] && exit 1; done
for a in "$@"; do [ "$a" = "rev-parse" ] && { echo "/nonexistent/review-clone"; exit 0; }; done
exit 0
STUB
  export CURL_PAYLOAD="$SANDBOX/payload.json"
  # curl stub: record the whole invocation, plus the JSON body on its own so
  # assertions can address individual fields. Returns CURL_CODE.
  cat >"$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CURL_LOG"
prev=""
for a in "$@"; do
  [ "$prev" = "--data-binary" ] && printf '%s' "$a" > "$CURL_PAYLOAD"
  prev="$a"
done
printf '%s' "${CURL_CODE:-202}"
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/git" "$SANDBOX/bin/curl"
  export PATH="$SANDBOX/bin:$PATH"
  unset PR_REVIEW_AUTO_APPROVE GH_POST_FAILS
}
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# write_config <jq-object-for-review-prs>
write_config() {
  jq -n --argjson rp "$1" '{"review-prs": $rp}' > "$HOME/.claude/fu-tools/config.json"
}

# Run pr_review_finish for one PR with a seeded sub-agent body.
# finish <pr> <decision> <body-extra>
finish() {
  local pr=$1 decision=$2 extra=${3:-}
  # cd into the sandbox: fu-config.sh walks up from cwd for a project config, and
  # this repo has one — running from the repo would not be hermetic.
  ( cd "$SANDBOX" && bash -c '
      set -uo pipefail
      source "$1"
      pr=$2; decision=$3; extra=$4
      { printf "<!-- DECISION: %s -->\n### Code review — PR #%s\n" "$decision" "$pr"
        [ -n "$extra" ] && printf "%s\n" "$extra"; } > "$STATE_DIR/review-body-$pr.md"
      printf "%s\n" "$decision" > "$STATE_DIR/decision-$pr.txt"
      write_pending "$pr" deadbeef cafef00d
      pr_review_finish "$pr"
    ' _ "$LIB" "$pr" "$decision" "$extra" 2>/dev/null )
}

curl_log()  { cat "$CURL_LOG" 2>/dev/null; }
log_text()  { cat "$HOME/.claude/pr-review/review-acme-widgets.log" 2>/dev/null; }

echo "== no config: nothing is notified (silent default) =="
new_sandbox
finish 7 COMMENT
eq "curl never invoked" "" "$(curl_log)"
cleanup

echo "== notify configured but no channels: still silent =="
new_sandbox
write_config "{\"teams_webhook\":\"$HOOK\"}"
finish 7 COMMENT
eq "curl never invoked" "" "$(curl_log)"
cleanup

echo "== teams: a posted review notifies, with PR, repo, title, decision and link =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
finish 7 COMMENT
out=$(curl_log)
has "webhook called" "$HOOK" "$out"
has "headline: repo, PR, state" "✅ widgets PR #7 — no blockers" "$out"
has "decision on the meta line" "posted COMMENT" "$out"

has "PR title fetched and shown" "<i>Fix null deref in OrderService</i>" "$out"
has "HTML emphasis on the headline" "<b>✅ widgets PR #7" "$out"
has "HTML line breaks" "<br>" "$out"
has "HTML link" '<a href=\"https://github.com/acme/widgets/pull/7\">Open PR</a>' "$out"
has "adaptive card wrapper too" "application/vnd.microsoft.card.adaptive" "$out"
has "card is colour-coded" "Good" "$out"
eq "card keeps the full owner/name" "acme/widgets" \
   "$(jq -r '[.card.body[] | select(.type=="FactSet") | .facts[] | select(.title=="Repo") | .value] | first' "$CURL_PAYLOAD")"
has "card has an Open PR action" "Action.OpenUrl" "$out"
eq "bare card at .card for a Post-card action" "AdaptiveCard" \
   "$(jq -r '.card.type' "$CURL_PAYLOAD")"
eq ".card and the attachment are the same card" "true" \
   "$(jq -r '.card == .attachments[0].content' "$CURL_PAYLOAD")"
eq "cardJson is the card, serialized" "true" \
   "$(jq -r '(.cardJson | fromjson) == .card' "$CURL_PAYLOAD")"
# summary is the notification preview a DIRECT channel webhook shows; the flowbot
# action drops it (it takes a bare card), which is why `text` is the default shape.
has "summary is a plain one-liner" "✅ widgets PR #7 — no blockers · posted COMMENT" \
   "$(jq -r '.summary' "$CURL_PAYLOAD")"
eq "messageJson envelope carries the summary" "true" \
   "$(jq -r '(.messageJson | fromjson) as $m
             | ($m.type == "message" and $m.summary == .summary)' "$CURL_PAYLOAD")"
has "success logged" "notify: teams ok (http 202)" "$(log_text)"
cleanup

echo "== a PR title containing markup is escaped in the HTML field =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
PR_TITLE='Fix <script>alert(1)</script> & "quotes"' finish 7 COMMENT
html=$(jq -r '.text' "$CURL_PAYLOAD" 2>/dev/null)
has "escaped tags" "&lt;script&gt;" "$html"
has "escaped ampersand" "&amp;" "$html"
has_no "no raw markup reaches the HTML field" "<script>" "$html"
# The card path is plain JSON text (Adaptive Card TextBlock renders a markdown
# subset, never HTML), so the title stays raw there — that is not an injection.
eq "card keeps the literal title" 'Fix <script>alert(1)</script> & "quotes"' \
   "$(jq -r '.attachments[0].content.body[1].text' "$CURL_PAYLOAD" 2>/dev/null)"
cleanup

echo "== a review with blockers is styled as such =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
finish 7 COMMENT "1. [BLOCKER] Boom — a.cs:1"
out=$(curl_log)
has "blocker headline" "🚧 widgets PR #7 — 1 blocker(s)" "$out"
has "card colour" "Attention" "$out"
cleanup

echo "== the webhook URL never reaches the log =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
finish 7 COMMENT
has_no "no sig in log" "SUPERSECRETSIG" "$(log_text)"
cleanup

echo "== blocker count is carried in the message =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
finish 7 COMMENT "1. [BLOCKER] Boom — a.cs:1
2. [BLOCKER] Bang — b.cs:2
3. [NIT] Meh — c.cs:3"
has "blocker count" "2 blocker(s)" "$(curl_log)"
cleanup

# --- delta-mode prior findings ------------------------------------------------
# The "Prior findings:" block re-prints each prior finding's ORIGINAL severity
# tag, so a fixed blocker still carries the literal "[BLOCKER]". Counting raw
# occurrences reported a fixed blocker as a live one — measured on
# EntityPlatform #2172, where a lone RESOLVED prior blocker was notified as
# "1 blocker(s)" while the body it linked to said "No blockers found".

echo "== a RESOLVED prior blocker is not a current blocker =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
finish 7 APPROVE "Prior findings:
1. RESOLVED — [BLOCKER] Correctness: unconditional write — a.cs:266

Found 0 issues:"
out=$(curl_log)
has "reported clean" "✅ widgets PR #7 — no blockers" "$out"
has_no "not styled as blocking" "blocker(s)" "$out"
has "card colour is Good" "Good" "$out"
cleanup

echo "== a STILL OPEN prior blocker does count =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
finish 7 COMMENT "Prior findings:
1. STILL OPEN — [BLOCKER] Correctness: unconditional write — a.cs:266"
has "counted" "🚧 widgets PR #7 — 1 blocker(s)" "$(curl_log)"
cleanup

echo "== a REINTRODUCED prior blocker does count =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
finish 7 COMMENT "Prior findings:
1. REINTRODUCED — [BLOCKER] Correctness: unconditional write — a.cs:266"
has "counted" "🚧 widgets PR #7 — 1 blocker(s)" "$(curl_log)"
cleanup

echo "== a RESOLVED prior blocker does not inflate a real count =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
finish 7 COMMENT "Prior findings:
1. RESOLVED — [BLOCKER] Correctness: unconditional write — a.cs:266
2. STILL OPEN — [BLOCKER] Scope: never touches the linked issue — b.cs:2

Found 1 new issues:
1. [BLOCKER] Boom — c.cs:3"
has "resolved one excluded, other two counted" "🚧 widgets PR #7 — 2 blocker(s)" "$(curl_log)"
cleanup

echo "== 'resolved' inside a live blocker's own text still counts =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
# Only a RESOLVED status *preceding* the tag is a fixed finding. The word
# appearing in the description is prose, not a status.
finish 7 COMMENT "1. [BLOCKER] Race is not resolved by the retry — a.cs:1"
has "still counted" "🚧 widgets PR #7 — 1 blocker(s)" "$(curl_log)"
cleanup

echo "== the sub-agent's APPROVE outranks any [BLOCKER] text in the body =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
# APPROVE means exactly "zero BLOCKERs" — the decision sidecar is authoritative,
# so a stray tag in prose must not contradict it in the notification.
finish 7 APPROVE "Found 0 issues: the prior [BLOCKER] no longer reproduces."
out=$(curl_log)
has "reported clean" "✅ widgets PR #7 — no blockers" "$out"
has_no "not styled as blocking" "blocker(s)" "$out"
# ...but the disagreement itself is news: overriding the count silently would
# hide a sub-agent that wrote real blockers into the body and APPROVE into the
# sidecar. The log alone is not enough — the log is what the notifier exists to
# avoid reading.
has "mismatch surfaced in the message" "decision APPROVE despite 1 [BLOCKER] tag(s) in the body" "$out"
has "mismatch logged too" "reporting 0" "$(log_text)"
cleanup

echo "== a genuinely clean APPROVE carries no mismatch note =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
finish 7 APPROVE "Found 0 issues:"
out=$(curl_log)
has "reported clean" "✅ widgets PR #7 — no blockers" "$out"
has_no "no mismatch note" "despite" "$out"
cleanup

echo "== a failed GitHub post notifies too =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
GH_POST_FAILS=1 finish 7 COMMENT
out=$(curl_log)
has "failure notified" "POST to GitHub failed" "$out"
has "failure is warning-coloured" "Warning" "$out"
cleanup

echo "== an empty review body notifies too =="
new_sandbox
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
( cd "$SANDBOX" && bash -c 'source "$1"; : > "$STATE_DIR/review-body-7.md"; pr_review_finish 7' _ "$LIB" ) 2>/dev/null
has "empty-body notified" "no review body produced" "$(curl_log)"
cleanup

echo "== unconfigured: no channels means no gh title lookup either =="
new_sandbox
finish 7 COMMENT
has_no "no PR title call" "Fix null deref" "$(curl_log)"
eq "curl never invoked" "" "$(curl_log)"
cleanup

echo "== teams selected without a webhook: logged, no curl, tick survives =="
new_sandbox
write_config '{"notify":["teams"]}'
finish 7 COMMENT
eq "curl never invoked" "" "$(curl_log)"
has "misconfiguration logged" "teams_webhook is unset" "$(log_text)"
cleanup

echo "== a non-2xx webhook response is logged, not fatal =="
new_sandbox 403
write_config "{\"notify\":[\"teams\"],\"teams_webhook\":\"$HOOK\"}"
finish 7 COMMENT
has "failure logged with code" "notify: teams FAILED (http 403)" "$(log_text)"
has "review still posted" "PR #7: posted COMMENT review" "$(log_text)"
cleanup

echo "== unknown channel is skipped with a log line =="
new_sandbox
write_config '{"notify":["carrier-pigeon"]}'
finish 7 COMMENT
eq "curl never invoked" "" "$(curl_log)"
has "unknown channel logged" "unknown channel 'carrier-pigeon'" "$(log_text)"
cleanup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
