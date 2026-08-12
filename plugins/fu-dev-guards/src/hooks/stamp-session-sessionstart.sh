#!/usr/bin/env bash
# SessionStart hook — hand the session its own Claude Code session id and ask for
# it to be stamped into PR bodies as an invisible HTML comment.
#
# Why this exists: months later you find a PR and want the session that wrote it.
# A session id resolves to a transcript at ~/.claude/projects/<slug>/<id>.jsonl,
# but the session has no way to learn its own id — nothing in its context carries
# it. A SessionStart hook is given it (.session_id), so it can pass it on.
#
# ADVISORY ONLY, deliberately. There is no PreToolUse hook denying an unstamped
# `gh pr create`. A deny would need to find the marker by grepping the RAW
# command string — the exact thing lib/git-guard.sh exists to avoid — and would
# then fire in every drive-by repo that never heard of the convention, costing a
# wasted turn. When a stamp is missed the trace is simply gone: there is no id to
# search by, so recovery means content-grepping every transcript under
# ~/.claude/projects. That is the accepted cost of not enforcing.
#
# Registered with NO matcher, so it re-fires on clear/compact/resume. That is
# load-bearing: a compaction drops the id from context, and without re-injection
# every PR after the first compaction in a long session would go unstamped.
#
# Ungated — every session, every directory, unlike the other hooks here. The
# marker is a v4 UUID and means nothing without this machine's ~/.claude, so
# there is no repo it is unsafe to land in; gating would only cost the trace in
# whichever repo was left out.
#
# The marker text is a WIRE FORMAT, not a wording choice: PRs stamped by older
# sessions are found by grepping for it. Changing it orphans them.

# jq is a hard dependency of every hook here. Say so on stderr rather than
# exiting quietly — a silent skip is indistinguishable from "no session id", and
# stamping would then never happen on this host with no signal that it stopped.
if ! command -v jq >/dev/null 2>&1; then
  printf 'fu-dev-guards: jq not found — session-id stamping disabled\n' >&2
  exit 0
fi

sid=$(jq -r '.session_id // ""' 2>/dev/null)

# No id (absent, empty, or unparseable input) means nothing to say. Say nothing
# rather than emitting an instruction with a hole where the id should be.
[ -n "$sid" ] || exit 0

# The marker is a single-line HTML comment, so an id carrying a newline would
# split it in half and a `>` could close the comment early — either way the wire
# format breaks and no grep finds it again. Emptiness is not enough of a check.
# Silent rather than loud on a mismatch: this fires only if the harness changes
# its id format, which is not something the user can fix, and complaining every
# SessionStart would be worse than the missed stamp.
case $sid in
  *[!A-Za-z0-9._-]*) exit 0 ;;
esac

# --arg, not interpolation: it keeps the id inert as JSON.
#
# "below the footer" rather than "the last line": every session also carries the
# built-in instruction to end PR bodies with the `🤖 Generated with Claude Code`
# line. Two rules both claiming the last line would be resolved at random, so
# this one yields position and states the order explicitly.
jq -nc --arg s "$sid" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: (
      "Claude Code session id for this session: " + $s + "\n\n" +
      "When you create a PR, put this line at the very bottom of the PR body, " +
      "verbatim — below the `🤖 Generated with Claude Code` footer if there is one:\n" +
      "<!-- claude-session: " + $s + " -->\n\n" +
      "It renders invisible on GitHub and lets a PR be traced back to the session that wrote it. " +
      "Carry it over when rewriting a body with `gh pr edit --body`, or the trace is lost."
    )
  }
}'
