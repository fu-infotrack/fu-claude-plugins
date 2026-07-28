#!/usr/bin/env bash
# fu-statusline — Claude Code status line renderer, a drop-in replacement for
# `npx ccstatusline`. Installed by the fu-statusline plugin; the `fu-statusline`
# token on this line is the marker install/uninstall use to recognise their own
# copy, so do not remove it.
#
# Renders the same five lines from the JSON payload on stdin, but without the
# 3.3 MB React/Ink bundle and without re-reading the whole transcript on every
# tick. Two things make it cheap:
#
#   * Token totals are cumulative over the entire session, so we keep a per-session
#     cache of the running totals plus the byte offset already consumed, and parse
#     only the bytes appended since the previous render.
#   * Git output is cached per directory for GIT_TTL seconds.
#
# Layout mirrors ~/.config/ccstatusline/settings.json as of the switchover:
#   1. model | thinking effort | context bar (slider) | session name
#   2. git branch | git changes
#   3. working directory
#   4. session cost | tokens cached/in/out/total
#   5. 5h usage | 5h reset | weekly usage | weekly reset

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
# Cache line, US separated: in_repo branch insertions deletions. The branch is
# empty on a detached HEAD, which is exactly the field a tab separator would
# swallow. The git2_ prefix marks the format; git_ files are ignored.
in_repo=0
branch=""
ins=0
dels=0
if [ -n "$dir" ] && [ -d "$dir" ]; then
    gkey=${dir//\//%}
    # Keep the key inside the filename length limit without letting distinct
    # directories collide onto one cache file.
    [ ${#gkey} -gt 200 ] && gkey="${#gkey}_${gkey:${#gkey}-190}"
    gcache="$CACHE_DIR/git2_$gkey"
    fresh=0
    if [ -r "$gcache" ]; then
        mtime=$(stat -c%Y "$gcache" 2>/dev/null || echo 0)
        [ $((now - mtime)) -lt "$GIT_TTL" ] && [ $((now - mtime)) -ge 0 ] && fresh=1
    fi

    if [ "$fresh" = 1 ]; then
        IFS="$SEP" read -r in_repo branch ins dels <"$gcache" || true
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
        fi
        printf '%s\x1f%s\x1f%s\x1f%s\n' "$in_repo" "$branch" "$ins" "$dels" \
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

    # Countdown as "2d 16hr 56m", dropping zero-valued leading units.
    def dur($secs):
        (if $secs < 0 then 0 else $secs end) as $x
        | (($x / 3600) | floor) as $th
        | ((($x % 3600) / 60) | floor) as $m
        | [ (($th / 24) | floor) as $d | if $d > 0 then "\($d)d" else empty end,
            ($th % 24) as $h | if $h > 0 then "\($h)hr" else empty end,
            (if $m > 0 then "\($m)m" else empty end) ]
        | if length > 0 then join(" ") else "0m" end;

    def slider($pct):
        ((([0, ([100, $pct] | min)] | max) / 100 * 10) | round) as $f
        | (("▓" * $f) // "") + (("░" * (10 - $f)) // "");

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
    | (($cw.used_percentage // 0) | floor) as $ctx_pct
    # The bar tracks the exact ratio; the printed percentage is the already
    # rounded one from the payload. ccstatusline splits these the same way, so
    # e.g. 14.7% prints as 15% but still fills only one of the ten cells.
    | (if $ctx_size > 0 then ($ctx_used / $ctx_size * 100) else 0 end) as $ctx_ratio
    | ($cached + $tin + $tout) as $tok_total

    | [
        ([ w($model; 30),
           w($p.effort.level // ""; 96),
           w("\(slider($ctx_ratio)) \(ftok($ctx_used; 0))/\(ftok($ctx_size; 0)) (\($ctx_pct)%)"; 26),
           w($title; 30) ] | line),

        ([ w(if $inrepo == 1 then $branch else "⎇ no git" end; 96),
           w(if $inrepo == 1 then "(+\($ins),-\($dels))" else "(no git)" end; 178) ] | line),

        ([ w($p.cwd // ""; 26) ] | line),

        ([ w("$" + fix2($p.cost.total_cost_usd // 0); 70),
           w(ftok($cached; 1); 30),
           w(ftok($tin; 1); 26),
           w(ftok($tout; 1); 188),
           w(ftok($tok_total; 1); 30) ] | line),

        ([ w(fix1($rl.five_hour.used_percentage // 0) + "%"; 111),
           w(dur(($rl.five_hour.resets_at // $now) - $now); 111),
           w(fix1($rl.seven_day.used_percentage // 0) + "%"; 111),
           w(dur(($rl.seven_day.resets_at // $now) - $now); 111) ] | line)
      ]
    | .[]
'
