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
#   sh -c 'git checkout main'                 (shell -c payload)
#
# Fix: split the command into segments on shell boundaries, strip each segment's
# leading assignments / wrapper words / backslash, then match the verb at the
# segment HEAD.
#
# Segmentation is QUOTE-AWARE: a boundary character only counts when it is not
# inside quotes, so ordinary prose in a quoted argument cannot trigger a false
# block — `echo "=== step A) git checkout ==="`, `git commit -m 'checkout done'`,
# `git log --grep 'git checkout'`, `echo "a && git checkout b"`. Quote-awareness
# does NOT lose real commands: `$(...)` and backticks re-enter command context
# even inside double quotes (so `y="$(git checkout main)"` still matches), and a
# `sh -c` / `bash -c` payload is rescanned as a command.
#
# Heredoc BODIES are treated the same way — data, not commands — so writing docs
# or a PR body that merely MENTIONS `git checkout` is not blocked. A quoted
# delimiter (<<'EOF') is fully inert; a bare one (<<EOF) still expands `$( )` and
# backticks, so only those are scanned. Text after the terminator is a command
# again. `<<<` is a here-string (data), not a heredoc.
#
# Single quotes are fully literal — the shell performs no substitution there, so
# nothing inside them can execute. An UNTERMINATED quote leaves the remainder
# literal and can therefore under-match; that is safe, because an unterminated
# quote is a shell syntax error and the command never runs.
#
# Usage: cmd_invokes "$cmd" 'git checkout' 'git switch' 'gh pr checkout'
#   returns 0 if any segment head starts with one of the (space-joined) phrases.

# Print the command text inside each $( ... ) or ` ... ` span of $1, one per line.
# Used for heredoc bodies: the body text itself is data, but its substitutions run.
_gg_expansions() {
  local s=$1 n=${#s} i ch depth inner
  for (( i = 0; i < n; i++ )); do
    ch=${s:i:1}
    if [ "$ch" = '$' ] && [ "${s:i+1:1}" = '(' ]; then
      depth=1; i=$((i + 2)); inner=''
      while [ "$i" -lt "$n" ] && [ "$depth" -gt 0 ]; do
        ch=${s:i:1}
        case $ch in
          '(') depth=$((depth + 1)); inner+=$ch ;;
          ')') depth=$((depth - 1)); [ "$depth" -gt 0 ] && inner+=$ch ;;
          *)   inner+=$ch ;;
        esac
        i=$((i + 1))
      done
      i=$((i - 1))
      printf '%s\n' "$inner"
    elif [ "$ch" = '`' ]; then
      i=$((i + 1)); inner=''
      while [ "$i" -lt "$n" ] && [ "${s:i:1}" != '`' ]; do inner+=${s:i:1}; i=$((i + 1)); done
      printf '%s\n' "$inner"
    fi
  done
}

# Consume the heredoc bodies queued in _GG_HD, starting at index $2 of string $1.
# Sets _gg_hd_end (index just past the last terminator) and _gg_hd_out (command
# text still worth scanning). A heredoc BODY is data, never commands: a quoted
# delimiter makes it fully inert, and a bare delimiter only expands substitutions
# — so just those are kept.
_gg_consume_heredocs() {
  local s=$1 pos=$2 spec q delim line body nl
  _gg_hd_out=''
  local n=${#s}
  for spec in "${_GG_HD[@]}"; do
    q=${spec%%|*}; delim=${spec#*|}; body=''
    while [ "$pos" -lt "$n" ]; do
      nl=${s:pos}; nl=${nl%%$'\n'*}          # current line
      line=${nl#"${nl%%[![:space:]]*}"}      # trimmed (covers <<- tab indent)
      pos=$((pos + ${#nl} + 1))
      [ "$line" = "$delim" ] && break
      body+=$nl$'\n'
    done
    [ -z "$q" ] && _gg_hd_out+=$(_gg_expansions "$body")$'\n'
  done
  _gg_hd_end=$pos
}

# Split $1 into command segments on unquoted shell boundaries.
# Prints one segment per line (segments may be empty).
_gg_segments() {
  local s=$1
  # Context stack; top element is the current context:
  #   c = command (top level, or inside $( ... ) / ( ... ) )
  #   b = command inside backticks         s = single quotes (literal)
  #   d = double quotes (literal except $( and backtick)
  local stack='c' cur='' out='' top ch nx i n=${#s}
  local -a _GG_HD=()
  local _gg_hd_out _gg_hd_end j c2 q delim

  for (( i = 0; i < n; i++ )); do
    ch=${s:i:1}
    top=${stack: -1}

    if [ "$top" = 's' ]; then                       # '...' — all literal
      if [ "$ch" = "'" ]; then stack=${stack%?}; else cur+=$ch; fi
      continue
    fi

    if [ "$top" = 'd' ]; then                       # "..." — literal + substitution
      case $ch in
        '"') stack=${stack%?} ;;
        '$') nx=${s:i+1:1}
             if [ "$nx" = '(' ]; then out+=$cur$'\n'; cur=''; stack+='c'; i=$((i + 1))
             else cur+=$ch; fi ;;
        '`') out+=$cur$'\n'; cur=''; stack+='b' ;;
        *)   cur+=$ch ;;
      esac
      continue
    fi

    case $ch in                                     # c / b — command context
      "'") stack+='s' ;;
      '"') stack+='d' ;;
      '`') out+=$cur$'\n'; cur=''
           if [ "$top" = 'b' ]; then stack=${stack%?}; else stack+='b'; fi ;;
      '$') nx=${s:i+1:1}
           if [ "$nx" = '(' ]; then out+=$cur$'\n'; cur=''; stack+='c'; i=$((i + 1))
           else cur+=$ch; fi ;;
      ';'|'|'|'&') out+=$cur$'\n'; cur='' ;;
      '<')  # `<<WORD` / `<<-WORD` / `<<'WORD'` opens a heredoc whose BODY is data,
            # not commands. Queue the delimiter; the body is consumed at the next
            # newline. `<<<` is a here-string (data on this line) — not a heredoc.
            if [ "${s:i+1:1}" = '<' ] && [ "${s:i+2:1}" != '<' ]; then
              j=$((i + 2))
              [ "${s:j:1}" = '-' ] && j=$((j + 1))
              while [ "${s:j:1}" = ' ' ]; do j=$((j + 1)); done
              q=''
              case ${s:j:1} in "'"|'"') q=${s:j:1}; j=$((j + 1)) ;; esac
              delim=''
              while [ "$j" -lt "$n" ]; do
                c2=${s:j:1}
                if [ -n "$q" ]; then
                  [ "$c2" = "$q" ] && { j=$((j + 1)); break; }
                else
                  case $c2 in ' '|$'\t'|$'\n'|';'|'&'|'|'|')') break ;; esac
                fi
                delim+=$c2; j=$((j + 1))
              done
              [ -n "$delim" ] && _GG_HD+=("$q|$delim")
              i=$((j - 1))
            else
              cur+=$ch
            fi ;;
      $'\n') out+=$cur$'\n'; cur=''
            if [ "${#_GG_HD[@]}" -gt 0 ]; then
              _gg_consume_heredocs "$s" $((i + 1))
              # Retained substitutions are commands in their own right — segment them.
              [ -n "${_gg_hd_out//[[:space:]]/}" ] && out+=$(_gg_segments "$_gg_hd_out")$'\n'
              i=$((_gg_hd_end - 1))
              _GG_HD=()
            fi ;;
      '(')  out+=$cur$'\n'; cur=''; stack+='c' ;;
      ')')  out+=$cur$'\n'; cur=''
            [ "${#stack}" -gt 1 ] && stack=${stack%?} ;;
      '{'|'}') out+=$cur$'\n'; cur='' ;;
      $'\t') cur+=' ' ;;
      *)    cur+=$ch ;;
    esac
  done

  printf '%s\n' "$out$cur"
}

# Strip a segment's leading noise: backslash, VAR=val assignments, wrapper words.
# Prints the bare command with internal whitespace runs collapsed.
_gg_strip() {
  local seg=$1 w
  seg=${seg#"${seg%%[![:space:]]*}"}
  while [ -n "$seg" ]; do
    if [ "${seg:0:1}" = '\' ]; then seg=${seg:1}; continue; fi
    w=${seg%%[[:space:]]*}
    case $w in
      *=*) ;;
      env|sudo|nohup|time|command|builtin|exec|nice|xargs|then|do|else) ;;
      *) break ;;
    esac
    seg=${seg#"$w"}; seg=${seg#"${seg%%[![:space:]]*}"}
  done
  while [ "$seg" != "${seg//  / }" ]; do seg=${seg//  / }; done
  printf '%s' "$seg"
}

cmd_invokes() {
  local cmd=$1; shift
  [ "$#" -gt 0 ] || return 1

  local seg verb payload
  while IFS= read -r seg; do
    seg=$(_gg_strip "$seg")
    [ -n "$seg" ] || continue

    # `sh -c '<payload>'` runs the payload: rescan it as its own command.
    case $seg in
      sh\ -c\ *|bash\ -c\ *|zsh\ -c\ *|dash\ -c\ *)
        payload=${seg#* -c }
        payload=${payload#[\"\']}; payload=${payload%[\"\']}
        cmd_invokes "$payload" "$@" && return 0 ;;
    esac

    # Head-match. The trailing space on both sides stops `git checkout` matching
    # `git checkout-index`, `git commit` matching `git commit-tree`, etc.
    for verb in "$@"; do
      case "$seg " in "$verb "*) return 0 ;; esac
    done
  done <<< "$(_gg_segments "$cmd")"

  return 1
}
