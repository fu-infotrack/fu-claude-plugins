#!/usr/bin/env bash
# fu-statusline — Claude Code status line renderer, a drop-in replacement for
# `npx ccstatusline`. Installed by the fu-statusline plugin; the `fu-statusline`
# token on this line is the marker install/uninstall use to recognise their own
# copy, so do not remove it.
#
# Renders the payload on stdin as four lines, without the 3.3 MB React/Ink
# bundle and without re-reading the whole transcript on every tick. Two things
# make it cheap:
#
#   * Token totals are cumulative over the entire session, so we keep a per-session
#     cache of the running totals plus the byte offset already consumed, and parse
#     only the bytes appended since the previous render.
#   * Git output is cached per directory for GIT_TTL seconds.
#
# Layout started from ~/.config/ccstatusline/settings.json and has diverged:
#   1. model | thinking effort | context bar (slider) | session name
#   2. git branch | ahead/behind the default branch | git changes
#   3. working directory
#   4. 5h usage | 5h reset | weekly usage | weekly reset | tokens | session cost
#
# Line 4 is ccstatusline's last two lines merged. The four rate-limit fields are
# padded to a constant width and lead, so they hold fixed columns; the two that
# grow with the session trail, where their jitter has nothing to push.

set -uo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cc-statusline"
GIT_TTL=5

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
# Cache line, US separated: in_repo branch insertions deletions ahead behind.
# The branch is empty on a detached HEAD, which is exactly the field a tab
# separator would swallow. The git3_ prefix marks the format; git_ and git2_
# files are ignored.
in_repo=0
branch=""
ins=0
dels=0
ahead=0
behind=0
if [ -n "$dir" ] && [ -d "$dir" ]; then
    gkey=${dir//\//%}
    # Keep the key inside the filename length limit without letting distinct
    # directories collide onto one cache file.
    [ ${#gkey} -gt 200 ] && gkey="${#gkey}_${gkey:${#gkey}-190}"
    gcache="$CACHE_DIR/git3_$gkey"
    fresh=0
    if [ -r "$gcache" ]; then
        mtime=$(stat -c%Y "$gcache" 2>/dev/null || echo 0)
        [ $((now - mtime)) -lt "$GIT_TTL" ] && [ $((now - mtime)) -ge 0 ] && fresh=1
    fi

    if [ "$fresh" = 1 ]; then
        IFS="$SEP" read -r in_repo branch ins dels ahead behind <"$gcache" || true
    else
        if [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
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
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
            "$in_repo" "$branch" "$ins" "$dels" "$ahead" "$behind" \
            >"$gcache.$$" 2>/dev/null && mv -f "$gcache.$$" "$gcache" 2>/dev/null
    fi
fi

# --- render ------------------------------------------------------------------
jq -rn \
    --argjson p "$payload" \
    --argjson now "$now" \
    --argjson cached "${tok_cached:-0}" \
    --argjson tin "${tok_in:-0}" \
    --argjson tout "${tok_out:-0}" \
    --argjson inrepo "${in_repo:-0}" \
    --arg branch "${branch:-}" \
    --argjson ins "${ins:-0}" \
    --argjson dels "${dels:-0}" \
    --argjson ahead "${ahead:-0}" \
    --argjson behind "${behind:-0}" \
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
    # font without them renders tofu, and terminals set to treat East Asian
    # Ambiguous as wide will render ʰ double-width.
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

    # Usage percent, zero-padded to two integer digits for the same reason: 8.0%
    # and 33.0% must occupy the same columns. 100.0% is one wider and is the only
    # state that moves the fields after it.
    def pct($x): (if $x < 10 then "0" else "" end) + fix1($x) + "%";

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

    | (($rl.five_hour.used_percentage // 0)) as $pct5
    | (($rl.seven_day.used_percentage // 0)) as $pct7
    # A clean tree is not news, so the diffstat only takes a colour once it moves.
    | (if ($ins + $dels) > 0 then c_warn else c_detail end) as $c_changes
    # Divergence from the default branch. Each side disappears at zero, and the
    # whole widget with it on a branch that sits exactly on the base — being some
    # commits ahead is the ordinary state of working, not a threshold crossing,
    # so it stays grey and the count itself is the signal.
    | ([ (if $ahead  > 0 then "⇡\($ahead)"  else empty end),
         (if $behind > 0 then "⇣\($behind)" else empty end) ] | join(" ")) as $div

    | [
        ([ w($model; c_primary),
           w($p.effort.level // ""; c_detail),
           w("\(slider($ctx_ratio)) \(ftok($ctx_used; 0))/\(ftok($ctx_size; 0))"; sev_ctx($ctx_pct; $ctx_used)),
           w($title; c_body) ] | line),

        ([ w(if $inrepo == 1 then $branch else "⎇ no git" end; c_body),
           w(if $inrepo == 1 then $div else "" end; c_detail),
           w(if $inrepo == 1 then "(+\($ins),-\($dels))" else "(no git)" end;
             if $inrepo == 1 then $c_changes else c_detail end) ] | line),

        ([ w($p.cwd // ""; c_body) ] | line),

        # ccstatusline splits usage across two lines: cost and the four-way token
        # breakdown, then the rate limits. Merged, ordered by how much each field
        # moves. The four rate-limit fields are constant-width by construction, so
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
