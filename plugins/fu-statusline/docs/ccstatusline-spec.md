# The ccstatusline render contract

`statusline.sh` implements the render contract of `ccstatusline@2.2.27`, reverse-engineered from
that package's minified bundle. **It is the expensive part of this plugin — the bundle is no
longer on disk.** If it is ever needed again: `npm view ccstatusline@2.2.27`.

Every formatting rule below still holds exactly. **The palette does not** — as of v0.2.0 the
colour codes are deliberately replaced, for reasons given under
[Palette](#palette-a-deliberate-divergence). Output was byte-identical to ccstatusline through
v0.1.1, and that is how the formatting was originally validated.

Every rule below is checked by `test/statusline.test.sh`, whose expectations were derived from
this document rather than captured from the implementation.

## Why the rewrite exists

The original was configured as `statusLine.command = "npx -y ccstatusline@latest"` with
`refreshInterval: 10`. Per session, every ten seconds, that meant a full `npx` resolve including
a registry hit (`-y` plus `@latest` defeats the cache), loading a 3.3 MB bundle carrying React,
Ink and react-devtools (the TUI config editor shares an entrypoint with the render path), and
`readFileSync` of the entire session transcript — twice, once for the session-name widget and
once for the token metrics.

With transcripts totalling 310 MB, the largest active one 47 MB, and nine concurrent sessions,
that measured **605 ms and 103 MB peak RSS per render**. The bash replacement is **12.3 ms and
11 MB** — 49× and 9.4×.

## Input

Claude Code writes one JSON object to the command's stdin. A real capture, redacted:

```json
{
  "session_id": "...", "transcript_path": "/home/<user>/.claude/projects/<slug>/<id>.jsonl",
  "cwd": "/home/<user>/repo/<name>",
  "effort": { "level": "xhigh" },
  "session_name": "-some-session",
  "model": { "id": "claude-sonnet-5", "display_name": "Sonnet 5" },
  "workspace": { "current_dir": "...", "project_dir": "...", "repo": {} },
  "version": "2.1.220",
  "cost": { "total_cost_usd": 80.09, "total_duration_ms": 168042148, "total_lines_added": 22 },
  "context_window": {
    "total_input_tokens": 76078, "total_output_tokens": 123,
    "context_window_size": 1000000,
    "current_usage": { "input_tokens": 2, "output_tokens": 123,
                       "cache_creation_input_tokens": 1459, "cache_read_input_tokens": 74617 },
    "used_percentage": 8, "remaining_percentage": 92
  },
  "rate_limits": {
    "five_hour": { "used_percentage": 33, "resets_at": 1785206400 },
    "seven_day": { "used_percentage": 28.000000000000004, "resets_at": 1785438000 }
  },
  "exceeds_200k_tokens": false, "fast_mode": false, "thinking": { "enabled": true },
  "pr": { "number": 12, "url": "..." }
}
```

Everything except the git widgets and the cumulative token totals comes straight from this
payload — **no HTTP calls are needed**, the rate limits arrive in it.

`context_window.current_usage` can be `null` on a fresh session, and `used_percentage` can be
absent. Both are treated as 0.

## Layout

From `~/.config/ccstatusline/settings.json` at the switchover: five lines, `minimalistMode:
true` (so no `Model: ` style labels), `defaultSeparator: " "`, `colorLevel: 2` (256-colour),
`gitCacheTtlSeconds: 5`.

| Line | Widgets (ccstatusline's original 256-colour code) |
|---|---|
| 1 | model (30), thinking-effort (96), context-bar slider (26), session-name (30) |
| 2 | git-branch (96), git-changes (178) |
| 3 | current-working-dir (26) |
| 4 | session-cost (70), tokens-cached (30), tokens-input (26), tokens-output (188), tokens-total (30) |
| 5 | session-usage (111), reset-timer (111), weekly-usage (111), weekly-reset-timer (111) |

The codes are not — see [Palette](#palette-a-deliberate-divergence). The composition no longer is
either:

- Since v0.4.0 line 2 carries a **divergence widget** between the branch and the changes, which
  ccstatusline has no equivalent of. See **Git** under [Formatting rules](#formatting-rules).
- Since v0.6.0 lines 4 and 5 are **one line**, ordered by volatility — see
  [The usage line](#the-usage-line).
- Since v0.7.0 line 3 **shortens the working directory** instead of printing `cwd` verbatim, under
  the constraint that the text still `cd`s. See **Working directory** under
  [Formatting rules](#formatting-rules).

So the render is four lines, not five.

Each widget renders as `ESC[38;5;<code>m<text>ESC[39m`. A widget producing no value is dropped
**along with its separator**, and a line whose widgets are all empty is dropped entirely. Each
surviving line is prefixed with `ESC[0m`.

## Formatting rules

**Whole-line NBSP substitution.** Once a line is assembled, ccstatusline runs
`line.replace(/ /g, "\xa0")`. This hits spaces *inside* widget text too, so `Opus 5` emits as
`Opus<NBSP>5`. ANSI sequences contain no spaces, so a global replace is safe. Get this wrong and
every line differs.

**`formatTokens(count, decimals = 1)`**

```js
if (count >= 1e6 - 500 / 10 ** decimals) return `${(count / 1e6).toFixed(1)}M`;
if (count >= 1000) return `${(count / 1000).toFixed(decimals)}k`;
return count.toString();
```

Note the odd threshold: 999950 for `decimals=1`, 999500 for `decimals=0`. The `M` branch is
always one decimal regardless. Token widgets use `decimals=1`; the context bar uses
`decimals=0`.

**Model name** — `display_name.replace(/\s*\(.*\)$/, "")`, so `Opus 5 (1M context)` → `Opus 5`.

**Context bar** — `SLIDER_WIDTH = 10`, `▓` filled, `░` empty,
`filled = Math.round(pct / 100 * width)`.

> The bar is computed from the **unrounded** ratio (`total_input_tokens / context_window_size *
> 100`) while ccstatusline printed the **already-rounded** `used_percentage` from the payload. So
> 14.7% printed `(15%)` but filled only one cell. Using the rounded value for both is an
> off-by-one that shows up around each x.5% boundary.

ccstatusline text: `<bar> <ftok(total_input_tokens, 0)>/<ftok(context_window_size, 0)>
(<used_percentage>%)`. The token count is `total_input_tokens` **only** — output tokens are not
included.

**Since v0.5.0 the trailing `(<pct>%)` is dropped** — a divergence. Ten cells and an explicit
`147k/1.0M` are already two renderings of how full the window is; the third was the widest field
on line 1 and the least specific of the three. `used_percentage` is still read, because it is one
of the two readings that **grade** the bar (see [Palette](#palette-a-deliberate-divergence)) —
that grading is where the number now shows up, as colour rather than digits.

**Session name** — *not* the payload's `session_name`. The widget scans the transcript backwards
for the last entry with `type === "custom-title"` and returns `entry.customTitle`, i.e. the
`/rename` title. The payload's `session_name` falls back to an AI-generated title, which
ccstatusline never shows — which is why a session named by `/rename` renders and an
auto-titled one appears blank.

**Cumulative token totals** — summed over the whole transcript, but filtered:

```js
// collect every entry with message.usage, in file order → parsedEntries
const hasStopReasonField = parsedEntries.some(e => Object.hasOwn(e.data.message, "stop_reason"));
const entriesToCount = hasStopReasonField
  ? parsedEntries.filter((entry, index) => {
      const sr = entry.data.message?.stop_reason;
      return Boolean(sr) || (sr === null && index === parsedEntries.length - 1);
    })
  : parsedEntries;
```

Then `cached = Σ(cache_read + cache_creation)`, `in = Σ input_tokens`, `out = Σ output_tokens`,
`total = cached + in + out`.

> This filter is the single subtlest thing here. It drops the partial entries a streamed
> response leaves behind; omitting it inflated `cached` by 0.3M on a 504M session. `stop_reason
> === null` is strict — an *absent* field is `undefined` and does **not** qualify, so jq needs
> `has("stop_reason")` to tell the two apart. Sidechain (subagent) entries **are** counted;
> there is no `isSidechain` filter on the sums.

**Git** — `rev-parse --is-inside-work-tree`; branch from `branch --show-current` (worktree
branches really are named `worktree-<name>`, with no transformation); changes from `diff
--shortstat` **plus** `diff --cached --shortstat`, parsed with `/(\d+)\s+insertions?/` and
`/(\d+)\s+deletions?/`, rendered `(+N,-M)`. Outside a repo the branch widget shows `⎇ no git`
and the changes widget `(no git)`.

**Divergence** (an addition, not in ccstatusline) — `rev-list --count --left-right <base>...HEAD`,
which prints `<behind>\t<ahead>`, rendered `⇡<ahead> ⇣<behind>`. Each side is omitted at zero and
the widget disappears with both, so a branch sitting on its base adds nothing to the line. It
stays `detail` grey in every state: being some commits ahead is the ordinary condition of working,
not a threshold crossing, and the count itself is what you read.

`<base>` is the **default branch**, resolved without touching the network:

1. `symbolic-ref --short refs/remotes/origin/HEAD` — a local ref written at clone time. This is
   what settles `main` vs `master`, and it is the case that normally hits.
2. Otherwise the first of `refs/remotes/origin/main`, `refs/remotes/origin/master`,
   `refs/heads/main`, `refs/heads/master` that exists — one `for-each-ref` call for all four,
   picked in that priority (remote outranks local of the same name), since `for-each-ref` sorts
   by refname rather than by pattern order. Reachable via `clone --single-branch`, or a clone made
   by a git old enough not to write `origin/HEAD`.
3. If none exists — a repo with no commits, or with no main/master at all — both counts stay 0 and
   the widget is absent.

**A status line must never fetch**, so the remote side of that comparison is only as current as
your last fetch: `⇣` understates silently and `⇡` may already be pushed. Treat it as divergence
from the last-known base, which is what the local refs actually record.

**Working directory** — ccstatusline prints `cwd` verbatim. Since v0.7.0 (a divergence) it is
shortened, bounded by the rule that the printed text must still reach the directory when pasted
into another shell. Only two shortenings survive that: `~` for `$HOME`, and a **glob prefix** for a
directory name.

`$HOME` always collapses. Past `CWD_BUDGET` (44 columns of the `~`-collapsed path) each middle
segment becomes the shortest prefix unique among its siblings plus `*`, with the last segment left
whole — `~/repo/fu-claude-plugins/.claude/worktrees/foo` → `~/r*/f*/.claude/w*/foo`.

Prefixes are computed against the real filesystem, one `readdir` per segment: the sibling set is
the hidden entries when the segment starts with `.` and the visible ones otherwise, matching how
the shell's own globbing treats a leading dot. A segment is left literal when it has no unique
prefix shorter than itself (`.claude` beside `.claude-plugin` — every candidate matches both), when
it is not on disk (the glob would expand to nothing), or when its name would need quoting to paste.
If the result is not shorter than what it replaced, the original is printed.

Ambiguity introduced later — a new sibling sharing a printed prefix — makes `cd` fail with `too
many arguments` rather than land elsewhere, which is what makes the trade acceptable. The prefix
search returns through a global, not `$(...)`: a fork per segment cost 5 ms of an 11 ms render.

**Durations** (reset timers)

```js
const totalHours = Math.floor(ms / 3600000);
const m = Math.floor((ms % 3600000) / 60000);
const d = Math.floor(totalHours / 24), h = totalHours % 24;
[d > 0 && `${d}d`, h > 0 && `${h}hr`, m > 0 && `${m}m`].filter(Boolean).join(" ") || "0m";
```

Zero-valued leading units are dropped: `36m`, `2d 16hr 56m`.

**The timer has diverged in three steps**, the first two aimed at reading it as a single value and
the third at making it stop moving:

```
2d 16hr 36m     ccstatusline
2d16h36m        v0.5.1   hr -> h, no inner separator
2ᵈ16ʰ36ᵐ        v0.5.2   units raised off the baseline
2ᵈ16ʰ36ᵐ        v0.6.0   every unit always printed, zero-padded
0ᵈ00ʰ36ᵐ        v0.6.0   ...which is what the 36m case now looks like
```

v0.5.1 dropped the inner spaces, because a space is the same character the line puts between its
widgets, so a multi-part countdown read as several fields. v0.5.2 raised the units off the baseline
(`ᵈ` U+1D48, `ʰ` U+02B0, `ᵐ` U+1D50) — with the spaces gone the digits and their unit letters sit
flush, and baseline letters at digit size blur into the number. Separating by glyph rather than by
colour keeps the whole timer at one grey: the palette spends hue on state only, and a countdown
ticking down is not a state change. The cost is a font dependency — these are the standard Unicode
modifier letters, but a terminal font lacking them renders tofu, and a terminal that treats East
Asian Ambiguous as wide renders `ʰ` double-width.

v0.6.0 stopped dropping zero-valued units and zero-padded the trailing ones, which is what makes
the width constant. ccstatusline's rule collapses `3ʰ28ᵐ` to `3ʰ` on the hour and `0ᵈ16ʰ36ᵐ` to
`16ʰ36ᵐ` for six days of every seven — six columns of movement in a group that now shares a line
with four other fields. The largest unit printed depends on the window: `Dᵈ HHʰ MMᵐ` for the weekly
timer, `Hʰ MMᵐ` for the 5-hour one, whose hours field is *total* hours so a value past 24 widens
rather than silently wrapping into a day it does not print.

The arithmetic is unchanged throughout.

The countdown is `resets_at - now`, both epoch seconds — `resets_at` straight off the payload,
`now` from `$CC_SL_NOW` when set (the test clock) else `printf '%(%s)T'`. Nothing is polled or
tracked between renders. A missing `resets_at` defaults to `now`, and a past one clamps at zero;
both print `0ʰ00ᵐ` / `0ᵈ00ʰ00ᵐ`.

**Usage percentages** — `toFixed(1)` plus `%`, e.g. `33.0%`. Since v0.6.0 the integer part is
zero-padded to two digits (`08.0%`) for the same width reason. `100.0%` is one wider and is the
only state that shifts the fields to its right. **Cost** — `$` plus `toFixed(2)`.

## The usage line

Since v0.6.0 ccstatusline's lines 4 and 5 are one line, ordered by how much each field moves:

```
33.0% 0ʰ36ᵐ 28.0% 2ᵈ16ʰ36ᵐ · 4.0k $80.09
└──────── constant width ────────┘   └── grows ──┘
```

The four rate-limit fields are constant-width by construction, so they lead and hold fixed columns
for the whole session. The token total and the cost only ever grow, so they trail — where a
widening field has nothing to its right to push. The fence (`·`, colour 240) marks the boundary.

That fence is the only glyph on the line carrying no value, and the only one below the AA floor the
other greys hold. It has to be findable enough to group its neighbours and quiet enough not to be
read as one of them — which is why it is a middot and not a box-drawing rule. The padding already
does the grouping; a `│` drew a wall where the boundary only wanted a pause.

`·` is East Asian Ambiguous, the same caveat as `ʰ`: a terminal configured to render that class
wide gives it two columns. It costs a column, not correctness.

**The cached / input / output breakdown is dropped.** It was three of the five most volatile fields
on the old line 4, its sum is the total that is still printed, and line 1 already carries the
context-window reading that made a cache-vs-input split worth seeing.

Widths, for the record: percent 5 (6 at exactly 100.0%), 5-hour timer 5, weekly timer 8, total 1–6,
cost 5–7. `test/statusline.test.sh` asserts the first four hold their shape across the floor, the
ceiling and several mid-window states of both windows.

## Palette: a deliberate divergence

Two problems with the inherited codes, one measurable and one structural.

**Measured.** On `#1e1e2e`, three of the seven fall below WCAG AA — but they are the three most
reused, between them covering nine of the sixteen fields:

| code | hex | ratio | used by |
|---|---|---|---|
| 26 | `#005fd7` | **2.83** | context bar, working dir, tokens-in |
| 96 | `#875f87` | 3.14 | effort, git branch |
| 30 | `#008787` | 3.76 | model, session name, tokens cached, tokens total |

The worst is the context bar, which is the most-glanced widget on the line. The other four codes
(`178`, `188`, `111`, `70`) pass on dark — and are exactly the four that fail on light, at 1.94,
1.33, 2.03 and 2.56. Between the two grounds every colour in the set fails somewhere.

**Structural, and the bigger of the two.** Hue marked *field type* — a property that never
changes and that position already encodes. Nothing marked *state*. Code 30 covered the model,
the session name, cached tokens and total tokens: four unrelated things. Colour was decoration.

The replacement puts structure in greys and spends hue only on state:

| Role | Code | Ratio on `#1e1e2e` | Applies to |
|---|---|---|---|
| primary | 253 | 11.73 | model, tokens-total |
| body | 248 | 6.90 | session name, git branch, cwd, cost |
| detail | 245 | 4.75 | effort, both reset timers, anything at rest |
| rule | 240 | 2.60 | the usage-line fence, and nothing else |
| ok | 108 | 6.65 | value under 60% |
| warn | 179 | 7.96 | 60–85%, and a dirty worktree |
| crit | 174 | 6.02 | value over 85% |

`sev($pct)` grades the context bar and each rate-limit percentage independently. The bar grades
on the **printed** (rounded) percentage, so the colour always agrees with the number beside it —
unlike the fill, which uses the exact ratio. The diffstat takes `warn` only when
`insertions + deletions > 0`. Reset timers never colour: a countdown is not news.

Thresholds are `> 85` crit, `>= 60` warn, else ok. All six boundaries are pinned by tests.

**Ground-specific.** These are tuned for a dark terminal and there is no set that serves both:
on `#fdf6e3` the old `188` measures 1.33:1, and this grey ramp would have to invert (roughly
234 / 238 / 241, with severity at 65 / 130 / 124).

## How the replacement stays cheap

Two mechanisms. Both matter; removing either puts the cost back.

**Incremental transcript reads.** `~/.cache/cc-statusline/<session_id>.tok2` holds a byte offset
plus running totals. Each render reads only `tail -c +<offset+1> | head -c <size - offset>`,
greps for `"usage"|"custom-title"`, and folds the delta in.

> The `head -c` bound matters: without it, a transcript that grows during the read gets
> partially re-counted on the next tick, because the recorded offset is the pre-read `size`.
> That bug produced totals a few entries too high. It is the one invariant here the test suite
> cannot stage deterministically.

Because the `stop_reason` filter has that "…or the last entry, if null" clause, the trailing
entry is **provisional** — a later entry demotes it. So the cache keeps three sets of sums:

- `s_*` — stable, only entries with a truthy `stop_reason`, monotonically accumulating;
- `a_*` — every entry, used only for legacy transcripts with no `stop_reason` field at all
  (`has_sr = 0`);
- `l_*` plus `last_null` — the trailing entry's contribution, recomputed each tick and added to
  `s_*` only when it qualifies.

**Torn-write guard.** If the transcript does not end in a newline, the tick is skipped entirely
and the cached values are reused; the next render picks it up. This avoids consuming half a line
and permanently losing it, at the cost of one possibly-stale render.

**Git caching.** Keyed per directory, 5 s TTL, matching `gitCacheTtlSeconds`. The divergence
counts ride in the same record and the same TTL, so they cost one extra `symbolic-ref` and one
`rev-list` on a cache miss and nothing on a hit: **14.9 ms → 17.8 ms** per cold render, 20 runs
each on this repo, with the warm path unchanged at 10 ms.

**Records are US-separated (0x1f), not tab-separated.** A tab is IFS *whitespace*, so bash
collapses runs of it: one empty field silently shifts every later field left. Both records here
have a field that is legitimately empty — the payload's `transcript_path`, and the branch name
on a detached HEAD, which sits in the *middle* of the git record and made the cached read
return `branch=0`. The `.tok2` and `git3_` names mark the format; files from an earlier one
(`git_`, `git2_`) are ignored rather than misparsed — **bump the prefix whenever the record gains
a field**, or an in-flight cache entry feeds short input to a longer `read`.

> Historical bug worth knowing: the key was originally `${gkey: -180}`, which evaluates to the
> **empty string** in bash, so every directory shared one cache file named `git_`. Sessions in a
> genuinely non-repo directory then poisoned it for all the others, and every session showed
> `⎇ no git`. Fixed with an explicit length check. If git widgets ever go wrong across the
> board, look here first.

## Validating a change

Parity with the original was established by A/B running both renderers against the same live
payloads: **25 of 27 renders were byte-identical across 9 concurrent sessions.** The 2 diffs
were a one-second clock skew crossing a minute boundary (`19m` vs `18m`) — timing, not formula.

To redo that (ccstatusline must be reinstalled first):

1. Write a wrapper that reads stdin once, runs both renderers on it, prints ccstatusline's
   output so the UI keeps working, and logs any diff.
2. Point `statusLine.command` at the wrapper. **Back up `settings.json` first.**
3. Let it collect across all sessions for a couple of minutes, then inspect.
4. Restore `statusLine.command`.

Two traps in that harness: redirect ccstatusline's stderr to `/dev/null` or npm warnings pollute
the comparison, and clear `~/.cache/cc-statusline/*.tok2` between runs or stale sums mask real
changes.

For an exact comparison with no timing skew, freeze a transcript: copy it, point a payload's
`transcript_path` at the copy with a synthetic `session_id`, and run both against that. The
script honours `CC_SL_NOW` (epoch seconds) to pin the clock — but pinning it to a *past* time
makes the git cache never look fresh, so git re-runs on every render. `test/statusline.test.sh`
relies on both of those.

## Gotchas

- The script parses Claude Code's payload schema directly. If that schema changes, the affected
  widget silently blanks rather than erroring. There is no schema version check.
- `jq`'s `|` binds **looser** than `,`, so `[ A | f, B | f ]` does not mean what it looks like.
  Array elements each need their own parentheses.
- jq cannot distinguish an absent key from a `null` value via `.key`; use `has("key")`. Required
  for the `stop_reason` logic.
- A transcript can contain a malformed JSON line. Any parser here must skip bad lines rather
  than abort — `jq` without `fromjson?` dies on it.
- The whole render program is one **single-quoted** bash argument, so an apostrophe anywhere in
  it — including inside a `#` comment — closes the quote and breaks the script. Measured: a
  comment reading `ccstatusline's` turned into `syntax error near unexpected token '|'` 4 lines
  later. `bash -n statusline.sh` catches it instantly; the test suite reports it as 40 failures
  with empty output, which reads like something much worse.
