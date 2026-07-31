# fu-review-prs

Automated PR-review orchestrator. One `/review-prs` tick finds open PRs that
need your review on the current repo, dispatches a Task sub-agent per PR (which
runs `/code-review` and writes a review body), and posts a formal GitHub review.
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

Mechanically: the sub-agent's `APPROVE` only means "zero BLOCKERs". `pr_review_init`
records the tick's mode to `state/<slug>/auto-approve`, and `pr_review_finish`
downgrades `APPROVE` → `COMMENT` when that file is absent. The mode lives on disk
for the same reason the decision does — a mid-tick compaction can't flip it — and is
cleared at cleanup so it never leaks into a later tick. `PR_REVIEW_AUTO_APPROVE=1`
is an equivalent env seam (used by the tests).

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
a sub-agent that produced no body. The failure cases matter most — they are the
silent misses you would otherwise only find by reading the log.

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

## Per-repo isolation

Lock, log, and state are namespaced by a repo slug (`owner/name` → `owner-name`),
so loops on different remotes run concurrently without contending on one lock,
and PR-number-keyed state never collides across repos:

```
~/.claude/pr-review/
  review-prs-<slug>.lock          # flock target, one per repo
  review-prs-<slug>.lock.holder   # holder PID
  review-<slug>.log
  state/<slug>/last-reviewed-<PR> # commit+tree of last review
  state/<slug>/prior-<PR>.txt     # prior findings (delta mode)
  state/<slug>/review-body-<PR>.md
  state/<slug>/auto-approve       # present only while a --auto-approve tick runs
```

The orchestrator resolves these via `pr_review_paths <PR>` and injects the
absolute paths into the sub-agent prompt — the sub-agent never builds its own.

## Pieces

- `commands/review-prs.md` — the per-tick orchestrator (context-thin).
- `scripts/lib.sh` — lock/setup/detect/finish helpers; sourced per Bash call.
- `review-task.md` — sub-agent spec: derive mode, read PR/linked-issue intent,
  run `/code-review`, scope-check the diff against the intent, write body, emit a
  `DECISION:` line. Posts nothing itself.
- `scripts/fu-config.sh` — the standard fu-tools config resolver (identical copy
  to the one the other plugins ship); used only by the notifier.
- `test/auto-approve.test.sh`, `test/notify.test.sh` — the posting-policy and
  notification contracts (hermetic: throwaway `HOME`, stubbed `gh`/`git`/`curl`).
