#!/usr/bin/env bash
# fu-statusline — Claude Code status line renderer, a drop-in replacement for
# `npx ccstatusline`. Installed by the fu-statusline plugin; the `fu-statusline`
# token on this line is the marker install/uninstall use to recognise their own
# copy, so do not remove it.
#
# Renders the payload on stdin as three lines, without the 3.3 MB React/Ink
# bundle and without re-reading the whole transcript on every tick. Two things
# make it cheap:
#
#   * Token totals are cumulative over the entire session, so we keep a per-session
#     cache of the running totals plus the byte offset already consumed, and parse
#     only the bytes appended since the previous render.
#   * Git output is cached per directory for GIT_TTL seconds.
#
# Layout started from ~/.config/ccstatusline/settings.json and has diverged:
#   1. model | thinking effort | context bar (slider) | output rate | session name
#   2. working directory | git branch | ahead/behind the default branch | changes
#   3. 5h usage | 5h reset | weekly usage | weekly reset | tokens | session cost
#
# Lines 2 and 3 are each a pair of ccstatusline lines merged, and both are ordered
# by how much a field moves: what holds still leads and what jitters trails, where
# a widening field has nothing to its right to push. On line 2 that puts the
# directory first (fixed for a session, and the widest) and the diffstat last; on
# line 3 the four rate-limit fields are padded to a constant width and lead, with
# the token total and cost — which only grow — behind them.

set -uo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cc-statusline"
GIT_TTL=5
# Target width of line 2 — directory plus the git widgets. What is left after the
# git widgets is what the directory may spend before it starts abbreviating, so a
# quiet git side buys columns and a long branch name gives them back. 56 leaves
# the directory the 44 it had when it was a line of its own and the git side is
# its usual `main (+0,-0)`.
LINE_TARGET=56

payload=$(cat)
[ -n "$payload" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
    printf '\033[0m(statusline: jq not found)\n'
    exit 0
fi

mkdir -p "$CACHE_DIR" 2>/dev/null

# US (0x1f) separates fields everywhere a record is split back apart. A tab
# cannot: bash treats IFS whitespace specially and collapses runs of it, so one
# empty field silently shifts every later field left. That is reachable — an
# absent transcript_path here, an empty branch on a detached HEAD below.
SEP=$'\x1f'

IFS="$SEP" read -r sid tpath dir < <(
    jq -r --arg s "$SEP" '[.session_id // "", .transcript_path // "", .cwd // .workspace.current_dir // ""] | join($s)' <<<"$payload"
) || exit 0

now=${CC_SL_NOW:-$(printf '%(%s)T' -1)}

# --- cumulative token totals -------------------------------------------------
# ccstatusline counts a transcript entry only if its message carries a truthy
# stop_reason, which excludes the partial entries a streamed response leaves
# behind. The exception is the very last entry with usage: it also counts when
# its stop_reason is present but null (a reply still in flight). That exception
# is provisional — the next entry demotes it — so the stable sums (s*) are kept
# apart from the trailing entry (l*), and only the stable ones accumulate.
# Transcripts predating the stop_reason field have none at all, so in that case
# every entry counts and the a* sums are used instead.
#
# Cache line, US separated (the .tok2 suffix marks that format; .tok files from
# the earlier tab-separated version are simply ignored):
#   offset s_cached s_in s_out a_cached a_in a_out has_sr last_null
#   l_cached l_in l_out custom-title
tok_cached=0
tok_in=0
tok_out=0
title=""
if [ -n "$tpath" ] && [ -f "$tpath" ] && [ -n "$sid" ]; then
    cache="$CACHE_DIR/$sid.tok2"
    offset=0 sc=0 si=0 so=0 ac=0 ai=0 ao=0 hs=0 ln=0 lc=0 li=0 lo=0
    if [ -r "$cache" ]; then
        IFS="$SEP" read -r offset sc si so ac ai ao hs ln lc li lo title <"$cache" || true
    fi

    size=$(stat -c%s "$tpath" 2>/dev/null || echo 0)
    # Transcript shrank (new session, or a compaction rewrote it) — start over.
    if [ "${size:-0}" -lt "${offset:-0}" ]; then
        offset=0 sc=0 si=0 so=0 ac=0 ai=0 ao=0 hs=0 ln=0 lc=0 li=0 lo=0 title=""
    fi

    # A transcript not ending in a newline means we caught a partial write. Skip
    # this tick rather than consuming half a line; the next render picks it up.
    if [ "${size:-0}" -gt "${offset:-0}" ] && [ -z "$(tail -c 1 "$tpath")" ]; then
        delta=$(
            tail -c "+$((offset + 1))" "$tpath" 2>/dev/null |
                head -c "$((size - offset))" |
                grep -aE '"usage"|"custom-title"' |
                jq -Rrn --arg title "$title" --arg s "$SEP" '
                    reduce inputs as $line (
                        {n: 0, sc: 0, si: 0, so: 0, ac: 0, ai: 0, ao: 0,
                         hs: 0, ln: 0, lc: 0, li: 0, lo: 0, title: $title};
                        ($line | fromjson? // null) as $e
                        | if $e == null then .
                          elif (($e.message?.usage? // null) != null) then
                              ($e.message) as $m
                              | ($m.usage) as $u
                              | (($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0)) as $c
                              | ($u.input_tokens // 0) as $i
                              | ($u.output_tokens // 0) as $o
                              | ($m | has("stop_reason")) as $present
                              | ($m.stop_reason) as $sr
                              | .n += 1
                              | (if $present then .hs = 1 else . end)
                              | .ac += $c | .ai += $i | .ao += $o
                              | (if ($sr != null and $sr != false and $sr != "")
                                 then .sc += $c | .si += $i | .so += $o
                                 else . end)
                              | .ln = (if ($present and $sr == null) then 1 else 0 end)
                              | .lc = $c | .li = $i | .lo = $o
                          elif $e.type == "custom-title" and (($e.customTitle // "") != "") then
                              .title = $e.customTitle
                          else . end
                    )
                    | [.n, .sc, .si, .so, .ac, .ai, .ao, .hs, .ln, .lc, .li, .lo, .title]
                    | map(tostring) | join($s)
                '
        )
        if [ -n "$delta" ]; then
            IFS="$SEP" read -r d_n d_sc d_si d_so d_ac d_ai d_ao d_hs d_ln d_lc d_li d_lo title <<<"$delta"
            sc=$((sc + d_sc)) si=$((si + d_si)) so=$((so + d_so))
            ac=$((ac + d_ac)) ai=$((ai + d_ai)) ao=$((ao + d_ao))
            [ "$d_hs" = 1 ] && hs=1
            # Only a delta that actually held usage entries moves the trailing one.
            if [ "${d_n:-0}" -gt 0 ]; then
                ln=$d_ln lc=$d_lc li=$d_li lo=$d_lo
            fi
        fi
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
            "$size" "$sc" "$si" "$so" "$ac" "$ai" "$ao" "$hs" "$ln" "$lc" "$li" "$lo" "$title" \
            >"$cache.$$" 2>/dev/null && mv -f "$cache.$$" "$cache" 2>/dev/null
    fi

    if [ "${hs:-0}" = 1 ]; then
        tok_cached=$((sc + (ln ? lc : 0)))
        tok_in=$((si + (ln ? li : 0)))
        tok_out=$((so + (ln ? lo : 0)))
    else
        tok_cached=$ac tok_in=$ai tok_out=$ao
    fi
fi

# --- git ---------------------------------------------------------------------
# Cache line, US separated: in_repo branch insertions deletions ahead behind top.
# The branch is empty on a detached HEAD, which is exactly the field a tab
# separator would swallow. The git4_ prefix marks the format; git_, git2_ and
# git3_ files are ignored.
in_repo=0
branch=""
ins=0
dels=0
ahead=0
behind=0
top=""
if [ -n "$dir" ] && [ -d "$dir" ]; then
    gkey=${dir//\//%}
    # Keep the key inside the filename length limit without letting distinct
    # directories collide onto one cache file.
    [ ${#gkey} -gt 200 ] && gkey="${#gkey}_${gkey:${#gkey}-190}"
    gcache="$CACHE_DIR/git4_$gkey"
    fresh=0
    if [ -r "$gcache" ]; then
        mtime=$(stat -c%Y "$gcache" 2>/dev/null || echo 0)
        [ $((now - mtime)) -lt "$GIT_TTL" ] && [ $((now - mtime)) -ge 0 ] && fresh=1
    fi

    if [ "$fresh" = 1 ]; then
        IFS="$SEP" read -r in_repo branch ins dels ahead behind top <"$gcache" || true
    else
        # Both answers from one process: --show-toplevel is what settles whether
        # the branch is the one this worktree implies (see line 2 below).
        IFS=$'\n' read -r -d '' inside top < <(
            git -C "$dir" rev-parse --is-inside-work-tree --show-toplevel 2>/dev/null
            printf '\0'
        )
        if [ "$inside" = "true" ]; then
            in_repo=1
            branch=$(git -C "$dir" branch --show-current 2>/dev/null)
            stats="$(git -C "$dir" diff --shortstat 2>/dev/null) $(git -C "$dir" diff --cached --shortstat 2>/dev/null)"
            while [[ $stats =~ ([0-9]+)[[:space:]]+insertion ]]; do
                ins=$((ins + BASH_REMATCH[1]))
                stats=${stats/"${BASH_REMATCH[0]}"/}
            done
            while [[ $stats =~ ([0-9]+)[[:space:]]+deletion ]]; do
                dels=$((dels + BASH_REMATCH[1]))
                stats=${stats/"${BASH_REMATCH[0]}"/}
            done

            # Commits ahead of / behind the default branch. origin/HEAD is a
            # local symbolic ref, so resolving it settles main-vs-master without
            # a network round trip; the fallback list covers a clone that never
            # had one written (git clone --single-branch, or an older git). Note
            # what this cannot do: a status line must never fetch, so the remote
            # side is only as current as your last fetch and "behind" understates
            # silently. Only the local refs are authoritative here.
            base=$(git -C "$dir" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
            if [ -z "$base" ]; then
                # One process for all four candidates; for-each-ref sorts by
                # refname, so pick by our own priority rather than by output order.
                have=$(git -C "$dir" for-each-ref --format='%(refname)' \
                    refs/remotes/origin/main refs/remotes/origin/master \
                    refs/heads/main refs/heads/master 2>/dev/null)
                for cand in refs/remotes/origin/main refs/remotes/origin/master \
                    refs/heads/main refs/heads/master; do
                    if [[ $'\n'$have$'\n' == *$'\n'$cand$'\n'* ]]; then base=$cand; break; fi
                done
            fi
            if [ -n "$base" ]; then
                # --left-right on a symmetric range prints "<behind>\t<ahead>".
                # An unborn HEAD makes this fail, leaving both at zero.
                counts=$(git -C "$dir" rev-list --count --left-right "$base...HEAD" 2>/dev/null)
                if [[ $counts =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
                    behind=${BASH_REMATCH[1]}
                    ahead=${BASH_REMATCH[2]}
                fi
            fi
        fi
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
            "$in_repo" "$branch" "$ins" "$dels" "$ahead" "$behind" "$top" \
            >"$gcache.$$" 2>/dev/null && mv -f "$gcache.$$" "$gcache" 2>/dev/null
    fi
fi

# --- line 2: working directory, then the git widgets -------------------------
# The directory is there to be copy-pasted into another terminal, so any
# shortening has to survive `cd <paste>`. That rules out every usual one — a
# middle ellipsis, one letter per segment, a repo-relative path — and leaves the
# two a shell puts back for you: `~` for $HOME, and a glob prefix for a
# directory name.
#
# So: always collapse $HOME, and once the line is over LINE_TARGET columns
# replace middle segments with the shortest prefix unique among their siblings
# plus `*`, leftmost first, stopping as soon as it fits. The last segment is
# never touched — it is the part actually read — and the outermost ancestors go
# first, since they say least about where you are. `cd` on the result reaches the
# same directory, and a prefix a later sibling makes ambiguous fails loudly
# (`cd: too many arguments`) rather than landing somewhere else.
#
# What it costs: pasting into something that is not a shell — an editor, a tool
# argument — now needs the `*`s expanded first. Only paths over budget pay it.

# Shortest prefix of <segment> that no sibling in <parent-dir> shares, plus `*`,
# assigned to $cwd_g. Leaves it empty (and the caller keeps the segment literal)
# when there is no prefix shorter than the name itself, when the name would need
# quoting to paste, or when the directory is not on disk.
#
# The result comes back in a global rather than on stdout because a `$(...)` here
# is a fork per path segment — 5 ms per render on a worktree path, half the whole
# render budget, for work that takes microseconds in-process.
cwd_glob() { # cwd_glob <parent-dir> <segment>
    # Separate statements: a builtin's words are all expanded before it runs, so
    # `local seg=$2 n=${#seg}` would read the *outer* seg — unset, which under
    # `set -u` kills the function and silently drops every abbreviation.
    local parent=$1 seg=$2
    local n=${#seg}
    cwd_g=""
    [ -d "$parent" ] || return 1
    # A name outside this set either needs quoting to paste as a bare word or
    # already holds glob metacharacters, neither of which prefix-matches safely.
    case $seg in *[^A-Za-z0-9._+@-]*) return 1 ;; esac
    # "ab" cannot beat "a*", so there is nothing to win below three characters.
    ((n > 2)) || return 1

    # One readdir, not one per candidate prefix. A pattern starting with `.`
    # matches only hidden entries and a pattern not starting with one matches
    # only visible entries, so the siblings that can collide are whichever class
    # the segment itself is in.
    local -a sibs names=()
    if [[ $seg == .* ]]; then sibs=("$parent"/.*); else sibs=("$parent"/*); fi
    local s base found=0
    for s in "${sibs[@]}"; do
        # nullglob is off, so an unmatched pattern comes back as itself.
        [ -e "$s" ] || continue
        base=${s##*/}
        case $base in . | ..) continue ;; esac
        [ "$base" = "$seg" ] && found=1
        names+=("$base")
    done
    # The segment has to be on disk, or the glob printed would match nothing.
    ((found)) || return 1

    local k pre clash
    for ((k = 1; k < n - 1; k++)); do
        pre=${seg:0:k}
        clash=0
        for base in "${names[@]}"; do
            [ "$base" = "$seg" ] && continue
            if [[ $base == "$pre"* ]]; then
                clash=1
                break
            fi
        done
        ((clash)) || {
            cwd_g="$pre*"
            return 0
        }
    done
    return 1
}

# The git widget *texts*, assembled here rather than in jq, because what is left
# of LINE_TARGET for the directory is the target minus whatever these take. jq
# still owns their colours.
#
# The branch is dropped when it is the one this directory already implies:
# EnterWorktree puts a worktree at <repo>/.claude/worktrees/<name> on a branch
# named worktree-<name>, so lines 2 and 3 used to print the same token twice —
# 31 columns of it for a name like `statusline-cwd-shorten`. Its absence is the
# statement "the branch is this worktree's own", which is why a detached HEAD can
# no longer render as absence too and now says so.
g_branch=""
g_div=""
g_changes=""
detached=0
if [ "$in_repo" = 1 ]; then
    if [ -z "$branch" ]; then
        detached=1
        g_branch="⎇ detached"
    else
        wt_name=""
        # Matches a multi-segment worktree name (`feat/x`) as well as a plain one.
        [ -n "$top" ] && [ "$top" != "${top#*/.claude/worktrees/}" ] &&
            wt_name=${top#*/.claude/worktrees/}
        [ -n "$wt_name" ] && [ "$branch" = "worktree-$wt_name" ] || g_branch="$branch"
    fi
    [ "$ahead" -gt 0 ] && g_div="⇡$ahead"
    [ "$behind" -gt 0 ] && g_div="${g_div:+$g_div }⇣$behind"
    g_changes="(+$ins,-$dels)"
else
    # One `⎇ no git` says it; the second widget saying `(no git)` beside it was
    # ccstatusline printing the same fact twice, which a merged line makes plain.
    g_branch="⎇ no git"
fi

# Columns these leave for the directory. Every non-empty widget costs its own
# width plus the space in front of it. Character counts, not display widths: the
# only non-ASCII glyphs here (⎇ ⇡ ⇣) are single-width.
cwd_budget=$LINE_TARGET
for cwd_w in "$g_branch" "$g_div" "$g_changes"; do
    [ -n "$cwd_w" ] && cwd_budget=$((cwd_budget - 1 - ${#cwd_w}))
done

cwd_disp=$dir
if [ -n "${HOME:-}" ] && [ -n "$cwd_disp" ]; then
    if [ "$cwd_disp" = "$HOME" ]; then
        cwd_disp="~"
    elif [ "${cwd_disp#"$HOME"/}" != "$cwd_disp" ]; then
        cwd_disp="~/${cwd_disp#"$HOME"/}"
    fi
fi

if [ ${#cwd_disp} -gt "$cwd_budget" ] && [[ $cwd_disp == "~/"* || $cwd_disp == /?* ]]; then
    # Walk the display segments while accumulating the real path alongside, since
    # the sibling lookup happens on disk and the display root may be `~`.
    cwd_root="" cwd_acc="" cwd_rest=""
    if [[ $cwd_disp == "~/"* ]]; then
        cwd_root="~" cwd_acc="$HOME" cwd_rest=${cwd_disp#\~/}
    else
        cwd_rest=${cwd_disp#/}
    fi
    IFS=/ read -r -a cwd_segs <<<"$cwd_rest"
    # Real parent of each segment, so the sibling lookup needs no re-walking.
    cwd_parents=()
    for cwd_seg in "${cwd_segs[@]}"; do
        cwd_parents+=("${cwd_acc:-/}")
        cwd_acc+="/$cwd_seg"
    done

    # Abbreviate one segment at a time, outermost first, and stop the moment the
    # line fits — a path only pays for the columns it is actually over by. A
    # segment with no usable prefix is skipped without ending the loop, and the
    # last segment is never a candidate.
    cwd_shown=("${cwd_segs[@]}")
    for ((cwd_i = 0; cwd_i < ${#cwd_segs[@]} - 1; cwd_i++)); do
        [ ${#cwd_disp} -le "$cwd_budget" ] && break
        cwd_glob "${cwd_parents[cwd_i]}" "${cwd_segs[cwd_i]}"
        [ -n "$cwd_g" ] || continue
        cwd_shown[cwd_i]=$cwd_g
        cwd_disp=$cwd_root
        for cwd_seg in "${cwd_shown[@]}"; do cwd_disp+="/$cwd_seg"; done
    done
fi

# --- render ------------------------------------------------------------------
jq -rn \
    --argjson p "$payload" \
    --argjson now "$now" \
    --argjson cached "${tok_cached:-0}" \
    --argjson tin "${tok_in:-0}" \
    --argjson tout "${tok_out:-0}" \
    --argjson inrepo "${in_repo:-0}" \
    --argjson ins "${ins:-0}" \
    --argjson dels "${dels:-0}" \
    --arg gbranch "${g_branch:-}" \
    --arg gdiv "${g_div:-}" \
    --arg gchanges "${g_changes:-}" \
    --argjson detached "${detached:-0}" \
    --arg cwd "${cwd_disp:-}" \
    --arg title "${title:-}" '
    # One decimal place, matching JS toFixed(1).
    def fix1($x): (($x * 10) | round) as $t | "\(($t / 10) | floor).\($t % 10)";
    def fix2($x):
        (($x * 100) | round) as $t | ($t % 100) as $r
        | "\(($t / 100) | floor).\(if $r < 10 then "0\($r)" else "\($r)" end)";

    # ccstatusline formatTokens(count, decimals)
    def ftok($c; $d):
        if $c >= (if $d == 0 then 999500 else 999950 end) then fix1($c / 1000000) + "M"
        elif $c >= 1000 then (if $d == 0 then (($c / 1000) | round | tostring) else fix1($c / 1000) end) + "k"
        else ($c | tostring) end;

    def z2($n): if $n < 10 then "0\($n)" else "\($n)" end;

    # Countdown as "2ᵈ16ʰ36ᵐ" (weekly) or "0ʰ28ᵐ" (5-hour). Three divergences from
    # ccstatusline "2d 16hr 36m", the first two aimed at reading the timer as ONE
    # value and the third at making it stop moving.
    #
    # No inner spaces: a space is what this line puts between its widgets, so a
    # multi-part countdown was separated by the same character as the widget
    # boundaries and read as separate fields.
    #
    # Superscript units (U+1D48 ᵈ, U+02B0 ʰ, U+1D50 ᵐ): with the spaces gone the
    # digits and their unit letters sit flush, and baseline letters at digit size
    # blur into the number. Raising the units off the digit line separates them by
    # glyph instead, which keeps the whole timer at one colour — the palette
    # spends hue on state only, and a countdown is not a state change. Cost is a
    # font dependency: these are the standard modifier letters, but a terminal
    # font without them renders tofu. Width is NOT a risk here, though this
    # comment used to say it was: ᵈ ʰ ᵐ (and the ᵗ on line 1) are all East Asian
    # width Neutral in Unicode 15.1. The two Ambiguous glyphs on these lines are
    # the fence · below and the context bar fill ▓, whose empty counterpart ░ is
    # Neutral -- so a terminal rendering that class wide widens the bar as it
    # fills.
    #
    # Constant width: every unit is always printed and the trailing ones are
    # zero-padded to two digits, so a timer is the same width in every state it
    # can reach. ccstatusline drops zero-valued units, which collapses 3ʰ28ᵐ to 3ʰ
    # on the hour and 0ᵈ16ʰ36ᵐ to 16ʰ36ᵐ for six of every seven days — six columns
    # of movement in the group these two fields share with four others.
    #
    # $lead names the largest unit printed: "d" for the weekly window, "h" for the
    # 5-hour. The hours field of an "h" timer is total hours, so a value past 24
    # widens rather than silently wrapping to a day it does not print.
    def dur($secs; $lead):
        (if $secs < 0 then 0 else $secs end) as $x
        | (($x / 3600) | floor) as $th
        | ((($x % 3600) / 60) | floor) as $m
        | if $lead == "d"
          then "\((($th / 24) | floor))ᵈ\(z2($th % 24))ʰ\(z2($m))ᵐ"
          else "\($th)ʰ\(z2($m))ᵐ" end;

    # Usage percent, right-aligned in 5 columns with spaces: ` 8.0%` and `33.0%`
    # occupy the same columns, so a window filling from single to double digits
    # moves nothing to its right. Space rather than a leading zero because the pad
    # is not a digit — `08.0%` reads as a value with two integer digits.
    #
    # `100.0%` is deliberately left one wider, the only state that shifts the
    # fields after it. Padding to 6 everywhere would buy stillness in a state that
    # almost never happens, at the cost of the one state where a line that jumps is
    # exactly the signal wanted. The pad sits inside the widget, so it becomes NBSP
    # with every other space on the line.
    def pct($x):
        (fix1($x) + "%") as $s
        | ((" " * (5 - ($s | length))) // "") + $s;

    def slider($pct):
        ((([0, ([100, $pct] | min)] | max) / 100 * 10) | round) as $f
        | (("▓" * $f) // "") + (("░" * (10 - $f)) // "");

    # Palette. Three tiers of grey carry the structure, and hue is spent only on
    # state, so a coloured cell always means a value crossed a threshold — glance
    # at a quiet line and there is nothing to read. The greys clear WCAG AA on a
    # dark ground (245 is 4.75:1 on #1e1e2e, 248 is 6.90, 253 is 11.73). The
    # ccstatusline defaults this replaced failed three of seven — the three most
    # reused ones — with the context bar worst at 2.83.
    def c_primary: 253;   # the two numbers actually worth reading
    def c_body:    248;   # identity fields
    def c_detail:  245;   # diagnostic detail, and anything at rest
    # Below the AA floor the other greys hold, deliberately: the fence is the one
    # glyph on the line carrying no value. It has to be findable enough to group
    # its neighbours and quiet enough not to be read as one of them.
    def c_rule:    240;   # group fence only — never a value
    def c_ok:      108;
    def c_warn:    179;
    def c_crit:    174;
    def sev($pct): if $pct > 85 then c_crit elif $pct >= 60 then c_warn else c_ok end;

    # Context takes the worse of two readings, because percent alone is the wrong
    # denominator once windows differ by 5x. Percent still carries compaction
    # proximity — a 200k-window model tops out below the first token step, so it
    # would otherwise sit quiet at 95% full. Absolute tokens carry the long-context
    # reading a 1M window hides: 300k tokens is 30% full and already past the first
    # step. Steps are 256k and 512k; they are bucket edges borrowed from how MRCR
    # results are binned, not a measured knee, so treat them as a prompt to look at
    # the printed count rather than a cliff.
    def sev_ctx($pct; $tok):
        if $pct > 85 or $tok >= 512000 then c_crit
        elif $pct >= 60 or $tok >= 256000 then c_warn
        else c_ok end;

    # 256-colour wrapper; empty widgets drop out along with their separator.
    def w($text; $c):
        if ($text // "") == "" then empty else "[38;5;\($c)m\($text)[39m" end;

    def line: map(select(. != null)) | join(" ")
        | if . == "" then empty else "[0m" + gsub(" "; " ") end;

    ($p.context_window // {}) as $cw
    | ($p.rate_limits // {}) as $rl
    | (($p.model.display_name // $p.model.id // "") | sub("\\s*\\(.*\\)$"; "")) as $model
    | ($cw.total_input_tokens // 0) as $ctx_used
    | ($cw.context_window_size // 0) as $ctx_size
    # Percent is no longer printed: ten cells and a token count already say how
    # full the window is, so a third rendering of the same number only widened
    # the line. It still *grades* the bar, so it is still computed.
    # NB: this jq program is single-quoted in bash — no apostrophes below.
    | (($cw.used_percentage // 0) | floor) as $ctx_pct
    # The bar tracks the exact ratio, not the rounded percent from the payload, so
    # 14.7% fills only one of the ten cells. ccstatusline splits these the same way.
    | (if $ctx_size > 0 then ($ctx_used / $ctx_size * 100) else 0 end) as $ctx_ratio
    | ($cached + $tin + $tout) as $tok_total

    # Session-average output throughput, printed beside the context bar because
    # both read the same thing -- what this session has spent -- one as a level
    # and one as a rate.
    #
    # Numerator is the cumulative OUTPUT tokens already parsed for line 3. Input
    # and cached tokens are read rather than generated, and at a wholly
    # different rate, so folding them in turns a 40 into a four-figure number
    # that measures nothing.
    #
    # Denominator is cost.total_api_duration_ms, NOT total_duration_ms. The
    # latter is session wall clock: the capture in docs/ccstatusline-spec.md
    # carries 168042148 ms of it -- 46.7 hours, nearly all of it a terminal
    # sitting idle. Divided by that, the widget would report how long the window
    # has been open, not how fast anything ran.
    #
    # Two ways to have no answer, and both print nothing rather than a zero.
    # Under a second of API time the denominator is small enough that a single
    # partial call swings the result by hundreds. And a rate that rounds to 0 is
    # a claim the session generated nothing, which is either false or not yet
    # true -- a fresh session, or a long idle one whose first reply has not
    # landed. In both states w() drops the widget along with its separator, so
    # line 1 is byte-identical to the pre-v0.10.0 line. Guarding on the rounded
    # RESULT rather than on the inputs is what catches the second case: 157
    # tokens over an hour of API time passes any input check and still prints
    # "0ᵗ".
    #
    # Rendered `39ᵗ` -- the raised modifier letter (U+1D57) is the whole unit,
    # and the per-second is implied. Three things make that read rather than
    # puzzle. It is the countdown idiom already on line 3 (`2ᵈ16ʰ36ᵐ`), where a
    # raised letter after digits means "this number is in these units", and ᵗ
    # comes from the same modifier-letter family as ᵈ ʰ ᵐ -- all East Asian
    # width Neutral -- so a font that renders the timers renders this. It also
    # carries no inner space, which the countdowns dropped for a reason worth
    # repeating: a space is what this line puts BETWEEN widgets, so a unit
    # separated by one reads as a second field.
    #
    # The one real ambiguity is the other number ᵗ could mean -- a token count
    # rather than a rate. What separates them is formatting, not the glyph:
    # every token COUNT on these lines goes through ftok and therefore carries a
    # k or M suffix (`147k/1.0M`, `4.0k`). A bare two- or three-digit number is
    # only ever this widget.
    #
    # Grey, not graded. The palette spends hue on state, and a throughput has no
    # threshold to cross -- it is a fact about the session, not news about it.
    #
    # Known asymmetry, and it only ever reads LOW: sub-agent transcripts are
    # separate files under <project>/<session>/subagents/, so their output
    # tokens never enter the numerator, while their API time -- same process --
    # almost certainly does enter the denominator. A fan-out heavy session
    # therefore under-reports. The transcript half of that is measured; the
    # denominator half is inferred from the process boundary, not instrumented.
    | (($p.cost.total_api_duration_ms // 0)) as $api_ms
    | (if $api_ms >= 1000 then (($tout * 1000 / $api_ms) | round) else 0 end) as $tps_n
    | (if $tps_n >= 1 then "\($tps_n)ᵗ" else "" end) as $tps

    | (($rl.five_hour.used_percentage // 0)) as $pct5
    | (($rl.seven_day.used_percentage // 0)) as $pct7
    # A clean tree is not news, so the diffstat only takes a colour once it moves.
    | (if ($ins + $dels) > 0 then c_warn else c_detail end) as $c_changes

    | [
        ([ w($model; c_primary),
           w($p.effort.level // ""; c_detail),
           w("\(slider($ctx_ratio)) \(ftok($ctx_used; 0))/\(ftok($ctx_size; 0))"; sev_ctx($ctx_pct; $ctx_used)),
           w($tps; c_detail),
           w($title; c_body) ] | line),

        # ccstatusline puts the git widgets on one line and the directory on the
        # next. Merged, ordered by movement like line 3: the directory is fixed for
        # a session and the widest field, so it leads; the diffstat is the only one
        # that changes while you work, so it trails.
        #
        # Every text here is assembled in bash — $cwd is shortened against the real
        # filesystem, and the widths of the other three are what decide how much
        # shortening it needs. jq only picks the colours. A detached HEAD is the one
        # state that takes hue: the branch widget is otherwise absent exactly when
        # the directory already implies the branch, and losing commits to a detached
        # HEAD is worth more than a grey.
        ([ w($cwd; c_body),
           w($gbranch; if $detached == 1 then c_warn else c_body end),
           w($gdiv; c_detail),
           w($gchanges; $c_changes) ] | line),

        # ccstatusline splits usage across two lines as well: cost and the four-way
        # token breakdown, then the rate limits. Merged, ordered by how much each
        # field moves. The four rate-limit fields are constant-width by construction, so
        # they lead and hold fixed columns for the whole session. Tokens and cost
        # only grow, so they trail — where a widening field has nothing to its
        # right to push. The fence (·, U+00B7) marks where the fixed part ends —
        # a pause rather than a wall, since the padding does the grouping and a
        # box-drawing rule would be louder than the boundary deserves.
        #
        # The cached/in/out breakdown is dropped. It was three of the five most
        # volatile fields on the line and its sum is the total already printed;
        # line 1 carries the context-window reading that made it useful.
        ([ w(pct($pct5); sev($pct5)),
           w(dur(($rl.five_hour.resets_at // $now) - $now; "h"); c_detail),
           w(pct($pct7); sev($pct7)),
           w(dur(($rl.seven_day.resets_at // $now) - $now; "d"); c_detail),
           w("·"; c_rule),
           w(ftok($tok_total; 1); c_primary),
           w("$" + fix2($p.cost.total_cost_usd // 0); c_body) ] | line)
      ]
    | .[]
'
