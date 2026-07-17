#!/usr/bin/env bash
# Shared PreToolUse helper for the git guards.
#
# Problem it solves: a naive `grep -qE '^\s*git\s+checkout'` anchors to the
# START of the whole command string, so the verb is only matched when it is the
# first token. Any command where the guarded verb is not first slips through:
#   git fetch origin && git checkout -b x     (chained — the proven bypass)
#   env FOO=1 git switch main                 (wrapper / assignment prefix)
#   sudo git checkout main
#   y=$(git checkout main)                    (command substitution)
#   printf ... ; git commit -m x              (any separator)
#   \git checkout main                        (alias bypass)
#
# Fix: split the command into segments on every shell boundary, strip each
# segment's leading assignments / wrapper words / backslash, then match the verb
# at the segment HEAD. Head-matching also AVOIDS false-blocking a verb that only
# appears inside a quoted argument, e.g. `git commit -m 'checkout done'` or
# `git log --grep 'git checkout'` — those are not at a segment head.
#
# Accepted trade-off: a boundary char INSIDE a quote (`echo "a && git checkout"`)
# over-splits and thus over-blocks. For a safety guard a false block is safe; a
# false pass defeats the guard. We deliberately do NOT do shell-accurate quote
# parsing. One residual gap in the same spirit: a leading assignment whose value
# is a quoted string containing spaces (`MSG="a b" git commit`) peels wrong and
# can under-match — rare, and not a shape an honest agent emits before a commit.
#
# Usage: cmd_invokes "$cmd" 'git checkout' 'git switch' 'gh pr checkout'
#   exit 0 if any segment head starts with one of the (space-joined) phrases.

cmd_invokes() {
  local cmd=$1; shift
  [ "$#" -gt 0 ] || return 1

  # Normalise every shell boundary to a newline: ; | & and the grouping /
  # substitution punctuation ( ) { } and backtick. `$(` is covered by `(`, and
  # `&&`/`||` collapse to newlines via their single chars. A literal newline is
  # already a boundary for the `read` loop below. Tab is intra-argument
  # whitespace (`git<TAB>checkout` is one command), NOT a separator, so fold it
  # to a space up front rather than splitting on it.
  local norm=${cmd//$'\t'/ } ch
  for ch in ';' '|' '&' '(' ')' '{' '}' '`'; do
    norm=${norm//"$ch"/$'\n'}
  done

  local seg w verb matched=1
  while IFS= read -r seg; do
    # trim leading whitespace
    seg=${seg#"${seg%%[![:space:]]*}"}
    # peel leading backslash (\git), VAR=val assignments, and wrapper words
    while [ -n "$seg" ]; do
      if [ "${seg:0:1}" = '\' ]; then seg=${seg:1}; continue; fi
      w=${seg%%[[:space:]]*}                 # first whitespace-delimited word
      case $w in
        *=*)                                 # VAR=val assignment
          seg=${seg#"$w"}; seg=${seg#"${seg%%[![:space:]]*}"} ;;
        env|sudo|nohup|time|command|builtin|exec|nice|xargs|then|do|else)
          seg=${seg#"$w"}; seg=${seg#"${seg%%[![:space:]]*}"} ;;
        *) break ;;
      esac
    done
    # collapse internal whitespace runs so `git   checkout` still head-matches
    while [ "$seg" != "${seg//  / }" ]; do seg=${seg//  / }; done
    # head-match: a trailing space in both operands stops `checkout` matching
    # `checkout-index`, `switch` matching `switchXYZ`, etc.
    for verb in "$@"; do
      case "$seg " in "$verb "*) matched=0; break 2 ;; esac
    done
  done <<< "$norm"

  return "$matched"
}
