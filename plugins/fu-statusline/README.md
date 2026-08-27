# fu-statusline

A Claude Code status line renderer in bash + jq. Replaces `npx -y ccstatusline@latest`: every one
of its formatting rules, at **12.3 ms / 11 MB** per render instead of **605 ms / 103 MB**
(49× / 9.4×).

It matched ccstatusline byte for byte through v0.1.1. Eight deliberate divergences since, all
below: v0.2.0 replaced the **palette**, v0.4.0 added a **divergence widget** ccstatusline has no
equivalent of, v0.5.0 **dropped the context percentage** — the bar and the token count already say
it — v0.5.1/v0.5.2 recut the **reset timers** as `2ᵈ16ʰ36ᵐ`, v0.6.0 **merged the last two lines**
into one that mostly holds its width, v0.7.0 **shortened the working directory** while keeping it
copy-pasteable, v0.8.0 **merged the directory and the git widgets** — five ccstatusline lines are
now three — and v0.10.0 added an **output-throughput widget** beside the context bar. Everything
else about the render contract is unchanged and still tested against it.

The original re-resolved a 3.3 MB React/Ink bundle from the registry and re-read the entire
session transcript twice, every ten seconds, per session. With nine sessions open that was a
measurable share of machine RAM. `docs/ccstatusline-spec.md` has the full story, the render
contract it reproduces, and the two mechanisms that keep it cheap.

## Install

```
/statusline-install
```

`statusLine` is not a plugin capability, and `${CLAUDE_PLUGIN_ROOT}` does not expand inside
`settings.json`, so the command copies the renderer to a stable path and patches settings:

| Path | Role |
|---|---|
| `~/.claude/statusline/statusline.sh` | the installed renderer (mode 755) |
| `~/.claude/settings.json` → `statusLine.command` | `~/.claude/statusline/statusline.sh` |
| `~/.claude/statusline/previous-statusline.json` | the `statusLine` this displaced, for uninstall |
| `~/.claude/statusline/settings.json.bak` | pre-change snapshot of `settings.json` |
| `~/.cache/cc-statusline/` | render cache: `<session_id>.tok2`, `git4_<escaped-dir>` |

Installing is idempotent, keeps a `padding` / `refreshInterval` you have tuned, and refuses —
changing nothing — if `settings.json` is malformed or a foreign file already sits at the install
path (`--force` overrides only the latter).

```
/statusline-uninstall               # restore the previous statusLine, remove the renderer
/statusline-uninstall --keep-script # leave the renderer on disk
/statusline-uninstall --purge       # also drop the cache and install directory
```

A `statusLine` pointing at something else is never touched.

Both commands are thin wrappers over `scripts/install.sh` and `scripts/uninstall.sh`, which are
runnable directly from a checkout.

## The palette

ccstatusline's default colours spend hue on **field type** — which never changes, and which
position already tells you. Code 30 marked the model, the session name, cached tokens and total
tokens: four things with nothing in common. Nothing marked **state**, which is the only reason to
glance at a status line. Three of the seven also failed WCAG AA on a dark terminal — the three
most reused, covering nine of the sixteen fields — with the context bar worst at 2.83:1.

So the palette is now three tiers of grey for structure, with hue reserved for state:

| Role | Code | Contrast on `#1e1e2e` | Used by |
|---|---|---|---|
| primary | 253 | 11.73:1 | model, total tokens |
| body | 248 | 6.90:1 | session name, git branch, working dir, cost |
| detail | 245 | 4.75:1 | effort, throughput, reset timers, anything at rest |
| rule | 240 | 2.60:1 | the usage-line fence, and nothing else |
| ok | 108 | 6.65:1 | under 60%, and under 256k tokens |
| warn | 179 | 7.96:1 | 60–85% or 256k–512k tokens, and a worktree with changes |
| crit | 174 | 6.02:1 | over 85% or at least 512k tokens |

The context bar and the two rate-limit percentages take their colour from their own value; the
diffstat colours only once the tree is dirty. A line with no colour in it needs nothing from you,
which is the property worth having — the reset timers stay grey precisely because a countdown is
not news.

The context bar no longer *prints* its percentage (v0.5.0) — ten cells and `147k/1.0M` are two
renderings of the same thing already, and the third was the widest field on line 1. The number
still grades the bar, so it shows up as colour instead of digits.

The rate-limit percentages are graded on percent alone. The **context bar is graded on both**
percent and absolute tokens, and shows whichever reading is worse, because percent alone is the
wrong denominator once window sizes differ by 5×:

- **Percent** carries compaction proximity. It is the only useful reading on a 200k window, which
  tops out below the first token step and would otherwise sit quiet at 95% full.
- **Absolute tokens** carry the long-context reading a 1M window hides. 300k tokens is 30% of that
  window and already past the first step.

The 256k and 512k steps are bucket edges borrowed from how MRCR long-context results are binned —
not a measured degradation threshold, and none is published for a current 1M-window model. Read an
amber bar on a large window as a prompt to look at the printed token count, not as a cliff.

Tuned for a dark ground. No single set of 256-colour codes reads well on both: on a light
terminal the old `188` measured 1.33:1, and these greys would need to invert.

## Output throughput

Since v0.10.0 line 1 carries a session-average output rate beside the context bar — the two
readings of what a session has spent, one as a level and one as a rate:

```
Opus 5 xhigh ▓░░░░░░░░░ 147k/1.0M 39ᵗ log-sweep
```

It is cumulative **output** tokens over `cost.total_api_duration_ms`. Both halves of that are
choices worth stating:

- **API time, not wall clock.** `cost.total_duration_ms` sits right beside it in the payload and
  is the wrong field — a real capture carries 46.7 hours of it, nearly all of it a terminal idle
  between turns. Dividing by that reports how long the window has been open, not how fast
  anything ran.
- **Output tokens only.** Input and cached tokens are read rather than generated, at a wholly
  different rate; including them turns a plausible 40 into a four-figure number that means
  nothing.

Under 1 s of accumulated API time, or when the rate **rounds to zero**, nothing is printed — not
`0ᵗ`. A denominator that small swings the answer by hundreds on one partial call, and a zero rate
claims the session generated nothing, which is either false or not yet true. The second guard is
on the rounded result rather than on the inputs, which is what catches a long-idle session: 157
output tokens over an hour of API time passes any "has output, has duration" check and still
prints `0ᵗ`. The widget drops out along with its separator, so those states render exactly the
pre-v0.10.0 line, as does a Claude Code too old to send the field.

It costs nothing measurable — two more jq expressions in a program that already runs, no extra
fork, no extra read. Best of five alternating runs of 20 warm renders: **12.65 ms → 12.50 ms**.

### Why the unit is one raised letter

`39ᵗ` spends three columns, and the per-second is implied. It reads because it is the countdown
idiom from line 3 (`2ᵈ16ʰ36ᵐ`) applied to a second kind of value: a raised modifier letter after
digits means "this number is in these units". `ᵗ` (U+1D57) is from the same family as `ᵈ ʰ ᵐ` and
is likewise East-Asian-width Neutral, so a font that renders the timers renders this — no new
dependency. And like the timers it carries **no inner space**, which matters for the same reason:
a space is the character this line puts *between* widgets, so `39 t/s` can read as two fields.

The one real ambiguity is the other thing a `ᵗ` could mean — a token *count* rather than a rate.
Formatting separates them, not the glyph: every token count on these lines goes through
`formatTokens` and so carries a `k` or `M` (`147k/1.0M`, `4.0k`). A bare two- or three-digit
number is only ever this widget.

Emoji were considered and rejected on measurement, not taste: ⚡ and 🚀 are East-Asian-width
**Wide**, so `⚡39` is four columns against this three, and both put hue on a line where hue is
reserved for a value crossing a threshold.

It stays grey in every state, like the reset timers: hue on these lines means a value crossed a
threshold, and a throughput has none to cross.

**It only ever reads low, and here is why.** Sub-agent transcripts are separate files under
`~/.claude/projects/<project>/<session>/subagents/`, so their output tokens never enter the
numerator, while their API time — same process — almost certainly enters the denominator. A
session that fans out to sub-agents therefore under-reports. The transcript half of that is
measured; the denominator half is inferred from the process boundary, not instrumented.

## The usage line

ccstatusline puts cost and a four-way token breakdown on one line and the rate limits on the next.
Since v0.6.0 they are one line, ordered by how much each field moves:

```
33.0% 0ʰ36ᵐ 28.0% 2ᵈ16ʰ36ᵐ · 4.0k $80.09
└──────── constant width ────────┘   └── grows ──┘
```

The four rate-limit fields are constant-width by construction, so they lead and hold fixed columns
for the whole session. The token total and the cost only ever grow, so they trail — where a
widening field has nothing to its right to push. Net effect: the line stops reflowing under the
cursor every ten seconds.

The fence is a middot rather than a box-drawing rule: the padding already groups the left half, so
the boundary wants a pause, not a wall. `·` (U+00B7) is East Asian Ambiguous, so a terminal set to
render that class wide gives it two columns — a column, not correctness. It is one of only two
Ambiguous glyphs on these lines; the other is `▓` (U+2593), whose empty counterpart `░` is Neutral,
so on such a terminal the context bar widens as it fills.

**The countdowns** print `2ᵈ16ʰ36ᵐ` where ccstatusline prints `2d 16hr 36m`. The spaces went first,
since the line already separates its widgets with a space and a countdown using spaces internally
read as two or three fields rather than one value. That left digits and unit letters flush, where
baseline letters at digit size blur into the number — so the units moved above the baseline (`ᵈ`
U+1D48, `ʰ` U+02B0, `ᵐ` U+1D50). Separating them by glyph rather than by colour keeps the timer at
one grey, which the palette above wants: hue means a value crossed a threshold, and a countdown
ticking down has not crossed anything. The cost is a font dependency — a font without the modifier
letters renders tofu. They are not a width risk: `ᵈ`, `ʰ` and `ᵐ` are all East-Asian-width
**Neutral** in Unicode 15.1, contrary to what earlier revisions of this file claimed.

**Constant width** comes from printing every unit and zero-padding the trailing ones, rather than
dropping zero-valued ones as ccstatusline does. That rule collapses `3ʰ28ᵐ` to `3ʰ` on the hour and
`0ᵈ16ʰ36ᵐ` to `16ʰ36ᵐ` for six days in seven. The percentages hold their width the same way, right-
aligned in 5 columns — with a **space** since v0.9.1 (`␠8.2%`), where v0.6.0 used a zero (`08.0%`)
and so read as a value with two integer digits. `100.0%` is one wider and is the only state that
shifts anything, deliberately: it almost never happens, and when it does a line that jumps is the
point.

**The cached / input / output breakdown is gone.** It was three of the five most volatile fields on
the old line, its sum is the total still printed, and line 1 already carries the context-window
reading that made the split worth seeing.

The values are display-only: `resets_at - now` in epoch seconds straight off the payload, a past or
absent reset clamped to zero. Nothing is polled or kept between renders.

## Line 2: the working directory and the git widgets

Since v0.8.0 these share a line, ordered like the usage line — what holds still leads, what jitters
trails:

```
~/repo/fu-claude-plugins main (+0,-0)                          37
~/r*/f*/.claude/worktrees/merge-git-cwd (+127,-63)             50   branch implied, not printed
~/r*/f*/.claude/w*/m*/plugins/fu-statusline (+127,-63)         54
/usr/share/doc ⎇ no git                                        22
```

The directory is fixed for a session and is the widest field, so it leads. The diffstat is the only
one that changes while you work, so it trails, where a widening field has nothing to its right to
push.

**The branch is dropped when the checkout already implies it.** `EnterWorktree` puts a worktree at
`<repo>/.claude/worktrees/<name>` on a branch named `worktree-<name>`, so the old lines 2 and 3
printed the same token twice — 31 columns of it for a name like `statusline-cwd-shorten`. The test
is `rev-parse --show-toplevel`, not the basename of the printed path, so a subdirectory of the
worktree counts too, and switching that worktree onto any other branch brings the name back.

Two consequences. Absence of the branch widget now *means* "the branch is this worktree's own", so
a **detached HEAD** can no longer render as absence as well: it says `⎇ detached`, and takes the one
hue on the line, because losing commits to a detached HEAD is worth more than a grey. And outside a
repo the second widget that used to repeat `(no git)` beside `⎇ no git` is gone — one statement of
a fact is enough, which a merged line makes obvious.

### Keeping the directory copy-pasteable

It is there to be pasted into another terminal, so every shortening has to survive `cd <paste>`.
That rules out the usual ones — a middle ellipsis, one letter per segment, a repo-relative path —
and leaves the two a shell puts back for you: `~` for `$HOME`, and a **glob prefix** for a
directory name.

`$HOME` always collapses. **`LINE_TARGET` (56) is a target for the whole line**, not a budget for
the directory: what the git widgets do not take is what the directory may spend, so a quiet git side
buys columns and a long branch name gives them back. `main (+0,-0)` leaves 43 — near the 44 the
directory had when it was a line of its own.

Over budget, middle segments become the shortest prefix unique among their siblings plus `*`,
**outermost first, stopping the moment the line fits** — the outer ancestors say least about where
you are, and a path only pays for the columns it is actually over by:

```
~/repo/fu-claude-plugins                       24   printed as-is
~/r*/f*/.claude/worktrees/merge-git-cwd        39   was 72; two segments were enough
~/r*/f*/p*/fu-s*/docs                          21   was 99
```

All of these `cd` to the same place in bash, zsh and fish. Prefixes are computed against what is
actually on disk, so a segment stays literal when it has no unique prefix — `.claude` beside
`.claude-plugin` has none, every candidate matches both — as does one that is not on disk, or one
whose name would need quoting to paste (a space, a glob character).

**Failure mode, and why it is acceptable:** clone a new sibling that shares a printed prefix and
that prefix becomes ambiguous. `cd` then fails with `too many arguments` — loudly, without landing
in the wrong directory, which is the property that makes the trade worth taking. The real cost is
pasting into something that is *not* a shell: an editor, a tool argument, a commit message. Only
paths over budget carry `*` at all.

Cost is one `readdir` per abbreviated segment and no forks — the prefix search returns through a
variable, because a `$(...)` per segment measured **+5 ms** on a worktree path, half the render
budget. Measured 20 cold renders on a 99-column path: **10 ms → 11 ms**.

## Divergence from the default branch

The git side of line 2 reads `<branch> ⇡<ahead> ⇣<behind> (+N,-M)`. Each arrow is omitted at zero
and the widget vanishes with both, so a branch level with its base costs nothing on the line.

The base is the default branch, resolved locally: `refs/remotes/origin/HEAD` if the clone has one
(it settles `main` vs `master` for you), else the first of `origin/main`, `origin/master`, local
`main`, local `master` that exists. No base — a repo with no commits, or with neither name — and
the widget stays absent.

**It never fetches.** A status line runs every few seconds; going to the network there is not an
option. So the remote side is only as current as your last fetch: `⇣` understates until you fetch,
and `⇡` can include commits you have already pushed. It is divergence from the last-known base,
which is what the local refs record.

It stays grey in every state, because being some commits ahead is the ordinary condition of
working, not a threshold crossing — and hue on this line already means "the tree is dirty".

Cost is one `symbolic-ref` and one `rev-list` behind the existing 5 s git cache — two more forks
on a miss, nothing on a hit. Measured on this repo, 20 cold renders each: **14.9 ms → 17.8 ms**.
Warm renders are untouched at 10 ms, and at most one render per directory per 5 s is cold.

## Configuration

None, deliberately. The layout and palette are hardcoded; paths derive from `$HOME` (or
`$CLAUDE_CONFIG_DIR` and `$XDG_CACHE_HOME` where set). Refresh cadence is Claude Code's own
`statusLine.refreshInterval`.

Making the layout configurable means reading `~/.config/ccstatusline/settings.json` and
reimplementing its widget registry and colour-name mapping in bash — a much larger job that was
considered and declined. That file, if present, is worth keeping as documentation of the spec.

## Dependencies

`jq` and `git`, both already assumed elsewhere in this marketplace. No node, no network.

## Tests

```bash
bash plugins/fu-statusline/test/statusline.test.sh   # render contract
bash plugins/fu-statusline/test/install.test.sh      # settings.json patching
```

The render expectations are worked out by hand from `docs/ccstatusline-spec.md`, not captured
from the implementation, so a formatting regression fails the suite instead of quietly
redefining the format. The install suite runs entirely against a throwaway `$HOME`.
