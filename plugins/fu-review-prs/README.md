# fu-review-prs

Automated PR-review orchestrator. One `/review-prs` tick finds open PRs that
need your review on the current repo, dispatches a Task sub-agent per PR (which
runs `/code-review` and writes its findings as JSON), renders the review body from
those findings, and posts a formal GitHub review.
Run it on an interval with `/loop` from inside a dedicated review clone.

```
cd <review-clone> && claude
/loop 30m /review-prs
```

The target repo is **auto-detected from cwd** (`gh repo view`), so run from
inside the clone. `gh` must be authenticated for that repo.

## Posting policy — COMMENT by default

Every review posts as a GitHub `COMMENT`, **including** reviews that found zero
BLOCKERs (the body then notes that no blockers were found). An `APPROVE` is a
durable, outward-facing signal that can satisfy branch protection and unblock a
merge, so it has to be asked for:

```
/loop 30m /review-prs --auto-approve    # clean PRs get an APPROVE
/loop 30m /review-prs                   # default: comment-only
```

`REQUEST_CHANGES` is never posted — it stays reserved for humans.

Mechanically: the verdict is `APPROVE` exactly when the findings hold zero current
BLOCKERs (see *Findings* below). `pr_review_init` records the tick's mode to
`state/<slug>/auto-approve`, and `pr_review_finish` downgrades `APPROVE` →
`COMMENT` when that file is absent. The mode lives on disk for the same reason the
findings do — a mid-tick compaction can't flip it — and is
cleared at cleanup so it never leaks into a later tick. `PR_REVIEW_AUTO_APPROVE=1`
is an equivalent env seam (used by the tests).

## Findings — the sub-agent classifies, bash does the rest

The sub-agent's whole deliverable is `findings-<PR>.json`, and its reply is `DONE`:

```json
{"findings": [{"severity": "BLOCKER", "text": "Null deref on an empty cart", "where": "src/Cart.cs:42"}],
 "prior":    [{"status": "RESOLVED", "severity": "BLOCKER", "text": "Unconditional write", "where": "a.cs:266"}]}
```

`pr_review_finish` derives everything else from that file:

- **The blocker count** is every `BLOCKER` in `findings` plus every prior
  `BLOCKER` that is `STILL OPEN` or `REINTRODUCED`.
- **The verdict** is `APPROVE` exactly when that count is zero.
- **The body** is rendered in a fixed layout: `### Code review — PR #N`, the
  "Prior findings:" block (DELTA only, as `1. STATUS — [TAG] text — \`where\``),
  then `Found N issues:` with each finding as `1. [TAG] text — \`where\``. Line
  breaks inside `text`/`where` become spaces.

Until v0.7.0 the sub-agent wrote the body in prose, plus a decision sidecar, and
bash parsed the count back out of the prose with a regex. That count could
disagree with the body. On `EntityPlatform` #2172, a lone RESOLVED prior blocker
was notified as `🚧 … 1 blocker(s)` while the review it linked to said *"No
blockers found"*. Now the count, the verdict and the body are three views of one
list, so they cannot disagree.

**Validation is strict.** An unknown severity or status, an empty `text`, a
non-string `where`, or invalid JSON rejects the whole file. Nothing posts, the
reason is logged, the "no review" notification fires, and the PR retries next
tick. A missing file takes the same path.

**Findings carry forward.** On a successful post, finish saves the live findings
to `last-findings-<PR>.json`: the current `findings` plus the prior ones still
open or reintroduced. The next pre-flight copies them into `prior-<PR>.json` for
the DELTA review to re-check. A review posted before v0.7.0 has no saved findings,
so its text is fetched from GitHub and passed as `{"findings":[],"legacy_body":…}`.

## House rules — findings that are BLOCKERs on their own

Findings normally come from `/code-review` and are graded on their own merits
(security, correctness, data loss, breaking interface change). On top of that,
`review-task.md` carries **house rules** — named patterns that are a BLOCKER with
no other defect required, because the pattern *is* the defect:

| Rule | Why it blocks |
|---|---|
| A method or function the PR **adds or renames** whose name carries the word `Mint` | `Mint` is a stock LLM verb, not vocabulary any codebase here uses. Reaching for it means the author never settled what the method actually does, so the name tells a reader nothing they can rely on. |

The `Mint` match is on **name segments**, not raw substring — the identifier is
split on camelCase/PascalCase boundaries and on `_`/`-`, and a segment equal to
`mint` (case-insensitive) hits. `MintToken`, `TryMintAsync`, `mint_creds` are
findings; `ConfirmIntent` and `Minutes` are not. Methods the PR only calls, or
leaves untouched, are out of scope: the rule is about names the PR introduces.

House rules live in the sub-agent spec, not in the portable spec
(`docs/pr-review-bot-spec.md`) — R31 already admits "documented-rule violation"
as a blocker class, and *which* rules a shop documents is not portable.

## Code vs. state

- **Code** ships in the plugin: `scripts/lib.sh` (orchestrator helpers) and
  `review-task.md` (sub-agent instructions). The command sources them via
  `${CLAUDE_PLUGIN_ROOT}`.
- **Mutable runtime state** lives under `~/.claude/pr-review/` — locks, logs,
  and per-PR state. It is kept OUTSIDE the plugin because the plugin cache is
  wiped and recopied on every reinstall.

## Notifications — opt-in, off by default

The bot reviews as **your** GitHub account, and GitHub never notifies you about
your own actions, so a finished review is otherwise invisible until you read the
log. Configure channels in `fu-tools` config; no config means silent:

```jsonc
// ~/.claude/fu-tools/config.json  (chmod 600 — the webhook URL is a credential)
{ "review-prs": {
    "notify": ["teams"],
    "teams_webhook": "https://…/triggers/manual/paths/invoke?…&sig=…"
} }
```

| Channel | Behaviour |
|---|---|
| `teams` | POSTs to a Power Automate ("Workflows") webhook — HTML message + Adaptive Card in one body |
| `bell`  | `BEL` to stderr — only useful if the loop's terminal is visible |

Fires at the three points where a tick's outcome becomes final: a posted review
(with its decision and BLOCKER count), a review whose POST to GitHub failed, and
a sub-agent that produced no usable findings. The failure cases matter most —
they are the silent misses you would otherwise only find by reading the log.

Every channel is best-effort and time-bounded (`curl --max-time 20`): a webhook
that 403s, hangs, or is misconfigured is logged and the tick carries on. The
webhook URL is never logged, echoed, or included in an error message.

### Teams webhook setup

Office 365 connectors are retired — use a Power Automate flow:

1. Teams → channel **⋯** → **Workflows** → template *"Post to a channel when a
   webhook request is received"*. For a DM instead, build the flow manually with
   the **"When a Teams webhook request is received"** trigger and a
   **"Post message in a chat or channel"** action (Post as *Flow bot*, Post in
   *Chat with Flow bot*).
2. On the trigger card set **"Who can trigger the flow?" → Anyone**. Any other
   setting demands an OAuth token, which a headless loop can't supply — the
   symptom is `401 DirectApiAuthorizationRequired`.
3. Copy the trigger URL (it contains `&sig=…`) into user config as above.

### Debugging the webhook

Test the flow without waiting for a review. Reads the URL from config, so it
never appears in your shell history or terminal:

```bash
hook=$(jq -r '."review-prs".teams_webhook' ~/.claude/fu-tools/config.json)
curl -sS -o /dev/null -w 'http %{http_code}\n' --max-time 20 \
  -H 'Content-Type: application/json' \
  -d '{"text":"<b>fu-review-prs</b> webhook test<br>if you can read this, the flow works"}' \
  "$hook"
```

To exercise the real renderer — same code path a tick uses, all payload shapes:

```bash
source ~/.claude/plugins/cache/fu-claude-plugins/fu-review-prs/<version>/scripts/lib.sh
ev=$(jq -n '{kind:"blockers", repo:"owner/repo", pr:"123", title:"Test PR title",
             decision:"COMMENT", blockers:"2", detail:"",
             url:"https://github.com/owner/repo/pull/123"}')
notify_teams "$ev"     # logs "notify: teams ok (http 202)"
```

`kind` is one of `clean`, `blockers`, `failed`, `nobody` — each renders a
different icon and colour. To see the exact bytes without sending, put a `curl`
stub earlier on `PATH` that dumps `--data-binary` (that is what
`test/notify.test.sh` does).

| Response | Meaning |
|---|---|
| `202` | Power Automate accepted the trigger — **not** proof the flow's action succeeded |
| `401` `DirectApiAuthorizationRequired` | trigger is not set to *"Who can trigger the flow?" → Anyone* |
| `403` | tenant policy / DLP blocking the call |
| `404` | URL wrong, or the flow was deleted or its URL rotated |
| `000` | timeout or no route out (`curl` never got a response) |
| `202`, but nothing in Teams | the flow ran and its **action** failed — open the run in Power Automate → the failed action → **Inputs** to see what it actually received |

That last row is the common one. `InvalidBotRequestMessageBody` means the field
got something that is not JSON — usually an expression typed into the plain
field instead of the **fx** tab, so it arrived as the literal text
`triggerBody()?['text']`.

### Which Teams action to use — measured

One payload carries the same content four ways, so any flow shape works:

| Payload field | Flow action | Field value |
|---|---|---|
| `text` (HTML) | **Post message in a chat or channel** ← recommended | `triggerBody()?['text']` |
| `cardJson` (string) | Post card in a chat or channel | `triggerBody()?['cardJson']` |
| `card` (object) | Post card, for flows that want an object | `triggerBody()?['card']` |
| `messageJson` (string) | a **direct channel webhook** (honours `summary`) | — |
| `attachments` | the ready-made Workflows templates | — (consumed as-is) |

Tested against a real flow — why **Post message** is the recommendation:

- Its Message field renders **HTML** (`<b> <i> <br> <a> <ul> <code>`). Markdown
  does not render, it shows as literal asterisks.
- A bot-posted Adaptive Card previews as *"sent a card"* in the toast and chat
  list, and **nothing you can put in the card changes that**: `fallbackText` is
  ignored, and the `summary` that a direct webhook honours can't get through —
  the flowbot action takes a bare card only and rejects the
  `{type, summary, attachments}` envelope with *"adaptive card request is
  missing or invalid"*. For a notifier the preview is the whole point, so the
  card's colours and Open PR button lose to a line you can triage from a toast.
- Want both? Put **two actions** in one flow: *Post message* (`text`) for the
  notification, then *Post card* (`cardJson`) for the visual. Costs two messages
  per review.
- **Post as: Flow bot**, not *User* — Teams never notifies you about messages
  you authored, so a flow posting as you lands silently. Same trap as GitHub
  not notifying you about your own reviews.
- Enter the field's value on the **fx / Expression** tab. Typed into the plain
  field it stays literal text and the flowbot rejects it with
  `InvalidBotRequestMessageBody: … message body is invalid JSON`.

## Heartbeat badge — opt-in, off by default

The bot reviews as *your* account, so teammates can't tell a bot is running.
With the heartbeat on, every tick that takes the lock (including `NO_WORK`
ticks) pings a small Cloudflare Worker (`worker/`). The Worker serves live
badges:

| URL | Shows |
|---|---|
| `GET /badge/<owner>/<repo>.svg` | green dot + last ping time (Sydney), red once older than **15 min**, grey `no bot` if it never pinged |
| `GET /badge.svg` | every live bot by repo name, or grey `no bot active` |

Badges are sent with `Cache-Control: public, max-age=60`. A dead bot drops off
`/badge.svg` by itself, so a retired repo needs no cleanup.

### Deploy the Worker (once)

A Workers Free account is enough. D1 is created on the first deploy (wrangler
≥ 4.45 auto-provisions it; nothing account-specific is committed):

```bash
cd plugins/fu-review-prs/worker
npx wrangler login
npx wrangler secret put PING_TOKEN        # paste a long random string, e.g. `openssl rand -hex 32`
CI=true npx wrangler deploy               # CI=true: don't write the D1 id back into wrangler.jsonc
```

`wrangler deploy` prints the Worker URL, `https://review-bot-heartbeat.<subdomain>.workers.dev`.

### Turn it on

In **user** config (`~/.claude/fu-tools/config.json`). The token is a bearer
credential, so it is never logged:

```json
{
  "review-prs": {
    "heartbeat_url": "https://review-bot-heartbeat.<subdomain>.workers.dev",
    "heartbeat_token": "<the PING_TOKEN value>",
    "heartbeat_footer": true
  }
}
```

Both `heartbeat_url` and `heartbeat_token` must be set. `heartbeat_footer`
(optional) embeds the repo's badge in every review footer. Email clients don't
render SVG, so the badge only shows on github.com. The ping is `curl -m 5`,
best-effort. A failure logs `heartbeat FAILED (http N)` and never fails the tick.

Check it: `curl -s <url>/badge.svg` after the next tick.

## Per-repo isolation

Lock, log, and state are namespaced by a repo slug (`owner/name` → `owner-name`),
so loops on different remotes run concurrently without contending on one lock,
and PR-number-keyed state never collides across repos:

```
~/.claude/pr-review/
  review-prs-<slug>.lock          # flock target, one per repo
  review-prs-<slug>.lock.holder   # holder PID
  review-<slug>.log
  state/<slug>/last-reviewed-<PR>      # commit/tree/reviewed_at of last posted review
  state/<slug>/last-findings-<PR>.json # findings still live after it (for the next DELTA)
  state/<slug>/pending-<PR>            # commit+tree being reviewed (pre-flight → finish)
  state/<slug>/scope-<PR>.txt          # REPO/HEAD/MODE/DELTA_BASE header + files to review
  state/<slug>/prior-<PR>.json         # prior findings (delta mode)
  state/<slug>/findings-<PR>.json      # the sub-agent's findings
  state/<slug>/auto-approve            # present only while a --auto-approve tick runs
```

Every per-PR name above comes from one function, `pr_path <kind> <pr>`. The first
two outlive a review and are purged once the PR closes. The rest last for one
dispatch. The
`last-reviewed-` and `pending-` records are `key=value` lines. `reviewed_at` is
GitHub's `submitted_at` for the posted review, and re-request detection compares
against it. Records written before v0.6.0 are two lines (commit, tree); they
still read, falling back to the file's mtime for `reviewed_at`.

Pre-flight prints the sub-agent's whole Task prompt after `PROCEED` (built by
`dispatch_prompt` from `pr_review_paths <PR>`), with the absolute paths already
injected. The orchestrator passes it verbatim and the sub-agent never builds its
own paths. `log()` writes only to the log file, so each step's output reaching the
orchestrator's context is just its token.

## Pieces

- `commands/review-prs.md` — the per-tick orchestrator (context-thin).
- `scripts/lib.sh` — lock/setup/detect/finish helpers; sourced per Bash call.
- `review-task.md` — sub-agent spec: read the scope pre-flight decided, read PR/linked-issue intent,
  run `/code-review` with an explicit `low` or `medium` level picked from the
  reviewed scope (never bare, so it never inherits an undefined level from the
  invoking context, and never above `medium` in an unattended tick),
  scope-check the diff against the intent, apply the house rules above, write
  the findings file, reply `DONE` and nothing else. Posts nothing itself.
- `scripts/fu-config.sh` — the standard fu-tools config resolver (identical copy
  to the one the other plugins ship); used by the notifier and the heartbeat.
- `worker/` — the heartbeat Cloudflare Worker: `src/badge-lib.mjs` (pure liveness
  + SVG logic, `node --test worker/test/*.test.mjs`) and `src/index.mjs` (the
  fetch handler over D1).
- `test/auto-approve.test.sh`, `test/findings.test.sh`, `test/notify.test.sh`,
  `test/preflight.test.sh`, `test/state.test.sh` — the posting-policy, findings,
  notification, pre-flight stdout and state-store contracts (hermetic: throwaway `HOME`, stubbed `gh`/`git`/`curl`).

## Docs

- `docs/orchestrator-subagent-pr-review-bot.md` — why this bot is shaped the way
  it is (the design rationale, in the order the lessons were learned).
- `docs/pr-review-bot-spec.md` — the same design as a portable conformance spec:
  OS-, language- and forge-agnostic ports, numbered requirements with their
  failure modes, a 34-case conformance suite, GitHub/GitLab/Azure DevOps
  bindings, and where this bash implementation deviates. Read it to port the bot
  to another language or platform.
