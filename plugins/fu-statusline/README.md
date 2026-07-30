# fu-statusline

A Claude Code status line renderer in bash + jq. Replaces `npx -y ccstatusline@latest`: every one
of its formatting rules, at **12.3 ms / 11 MB** per render instead of **605 ms / 103 MB**
(49× / 9.4×).

It matched ccstatusline byte for byte through v0.1.1. Five deliberate divergences since, all below:
v0.2.0 replaced the **palette**, v0.4.0 added a **divergence widget** ccstatusline has no
equivalent of, v0.5.0 **dropped the context percentage** — the bar and the token count already say
it — v0.5.1/v0.5.2 recut the **reset timers** as `2ᵈ16ʰ36ᵐ`, and v0.6.0 **merged the last two
lines** into one that mostly holds its width. Everything else about the render contract is
unchanged and still tested against it.

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
| `~/.cache/cc-statusline/` | render cache: `<session_id>.tok2`, `git3_<escaped-dir>` |

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
| detail | 245 | 4.75:1 | effort, reset timers, anything at rest |
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

## The usage line

ccstatusline puts cost and a four-way token breakdown on one line and the rate limits on the next.
Since v0.6.0 they are one line, ordered by how much each field moves:

```
33.0% 0ʰ36ᵐ 28.0% 2ᵈ16ʰ36ᵐ │ 4.0k $80.09
└──────── constant width ────────┘   └── grows ──┘
```

The four rate-limit fields are constant-width by construction, so they lead and hold fixed columns
for the whole session. The token total and the cost only ever grow, so they trail — where a
widening field has nothing to its right to push. Net effect: the line stops reflowing under the
cursor every ten seconds.

**The countdowns** print `2ᵈ16ʰ36ᵐ` where ccstatusline prints `2d 16hr 36m`. The spaces went first,
since the line already separates its widgets with a space and a countdown using spaces internally
read as two or three fields rather than one value. That left digits and unit letters flush, where
baseline letters at digit size blur into the number — so the units moved above the baseline (`ᵈ`
U+1D48, `ʰ` U+02B0, `ᵐ` U+1D50). Separating them by glyph rather than by colour keeps the timer at
one grey, which the palette above wants: hue means a value crossed a threshold, and a countdown
ticking down has not crossed anything. The cost is a font dependency — a font without the modifier
letters renders tofu, and a terminal treating East Asian Ambiguous as wide renders `ʰ` double-width.

**Constant width** comes from printing every unit and zero-padding the trailing ones, rather than
dropping zero-valued ones as ccstatusline does. That rule collapses `3ʰ28ᵐ` to `3ʰ` on the hour and
`0ᵈ16ʰ36ᵐ` to `16ʰ36ᵐ` for six days in seven. Percentages are zero-padded to two integer digits for
the same reason (`08.0%`); `100.0%` is one wider and is the only state that shifts anything.

**The cached / input / output breakdown is gone.** It was three of the five most volatile fields on
the old line, its sum is the total still printed, and line 1 already carries the context-window
reading that made the split worth seeing.

The values are display-only: `resets_at - now` in epoch seconds straight off the payload, a past or
absent reset clamped to zero. Nothing is polled or kept between renders.

## Divergence from the default branch

Line 2 reads `<branch> ⇡<ahead> ⇣<behind> (+N,-M)`. Each arrow is omitted at zero and the widget
vanishes with both, so a branch level with its base costs nothing on the line.

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
