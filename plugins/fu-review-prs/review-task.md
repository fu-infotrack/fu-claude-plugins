# PR Review Task

Your deliverable for PR #<PR> is written to **disk** (so it survives even if the
orchestrator's context is compacted after you return):

1. A findings file at `FINDINGS_FILE` — JSON, in the shape Step 3 gives.
2. A response that is **exactly** `DONE` — nothing else (the orchestrator reads
   the file above; your reply only costs it context).

You classify findings; the orchestrator does everything else. It renders the review
body from your file, derives the verdict and the blocker count from it, and posts
it. You do **NOT** post anything to GitHub yourself, and you do not write prose, a
body, or a verdict. Running `/code-review` is only how you *gather* findings; it is
NOT the end of your task. After `/code-review` returns, you MUST still do Steps 2–4.
Do not stop after `/code-review`.

## GitHub access: REST only

This review may run in a Claude Code cloud session, where GitHub's GraphQL API
is blocked: every GraphQL request fails with HTTP 403. `gh pr view`,
`gh pr list`, `gh pr checkout`, `gh issue view` and `gh repo view` are GraphQL
underneath, so **do not use them**, wherever you run. What works everywhere:

| Need | Use |
|---|---|
| PR title, body, author, head | `gh api repos/<REPO>/pulls/<PR>` |
| The diff | `gh pr diff <PR> --repo <REPO>` |
| An issue | `gh api repos/<REPO>/issues/<N>` |
| An issue's comments | `gh api "repos/<REPO>/issues/<N>/comments?per_page=100&page=1"` |
| A file at a commit | `gh api repos/<REPO>/contents/<path>?ref=<sha>` |

`/code-review` may reach for a GraphQL command; when one fails with
"GraphQL is not available", use the REST equivalent above and carry on.

**Never pass `--paginate` to `gh api`.** It follows GitHub's next-page link,
which names the repo as `repositories/<id>/...`, and the cloud session's proxy
rejects that with HTTP 403, failing the whole call. Ask for pages by number
instead: `?per_page=100&page=1`, and when a page returns 100 items, ask for
`page=2`, and so on.

**The PR's head is already checked out** for you, detached, in the worktree at
`REVIEW_DIR`. Read, grep and blame the code there. Every Bash call starts in the
checkout the loop runs from, not in `REVIEW_DIR`, so always pass absolute paths
(`Read`/`Grep` on `REVIEW_DIR/...`, `git -C REVIEW_DIR log`/`blame`).

## Step 0 — Review context and PR intent

`SCOPE_FILE`, `PRIOR_FILE`, `FINDINGS_FILE` and `REVIEW_DIR` are given to you as
absolute paths in your task prompt. Use them verbatim — do not construct your own
(they are namespaced per repo, so a hand-built path will be wrong).

1. Read `SCOPE_FILE` — the orchestrator has already decided what you review. It is a
   header, a blank line, then one file path per line:

   ```
   REPO=<owner/name>
   HEAD=<head commit you review>
   MODE=FULL | DELTA
   DELTA_BASE=<last reviewed commit; empty in FULL mode>
   ```

   Use `<REPO>`, `<head_commit>` and `<delta_base>` to mean these values below. The
   file list is your **review scope**: every PR file in FULL mode; in DELTA mode, only
   the PR's files that changed since `DELTA_BASE` (rebased-in main files already
   excluded). Do not re-derive the mode or the list, and do not widen it.
2. Read the PR's stated intent so you can judge whether the diff actually delivers it:
   - `gh api repos/<REPO>/pulls/<PR> --jq '{title, body}'`
   - The REST API has no list of the issues a PR closes, so find them in the body: every `#<N>` after a closing keyword (`close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`, any case). Read each **including its comments**: `gh api repos/<REPO>/issues/<N> --jq '{title, body, labels: [.labels[].name]}'` and `gh api "repos/<REPO>/issues/<N>/comments?per_page=100&page=1" --jq '.[] | {author: .user.login, body}'` (the next `page` while one returns 100). Also scan the PR body for other `#<n>` mentions and read up to ~3 of them; ignore the rest (stay bounded).
   - **Read the issue comments, not just the body.** Product managers / maintainers often post the real detail there — clarifications, revised acceptance criteria, or scope cuts added after the issue was opened. Fold genuine requirement updates into the intent, and where a later clarifying comment conflicts with the original body, **the comment wins**. Ignore bot/status/CI chatter and side discussion; weight the issue author's and maintainers' clarifying comments.
   - Distil one line of **stated intent** (the issue's core ask, as refined by its clarifying comments, + the PR's own description). You compare the diff against it in Step 2. If there is no linked issue **and** the PR body is empty, record "no stated intent" and skip the scope check entirely (do not invent requirements). A body holding **only HTML comments** counts as empty — `fu-dev-guards` stamps `<!-- claude-session: <uuid> -->` into every PR body, so a genuinely description-less PR is no longer literally empty. Never distil intent from a marker comment.

The orchestrator only spawns you when there is work to do — do not re-check whether the PR should be skipped.

## Step 1 — Run `/code-review` to gather findings

Invoke the `/code-review` slash command on PR #<PR>, always with an explicit level — `low` or `medium` — never bare `/code-review`: without an explicit level it reuses whatever level was last typed in the invoking context, which for a fresh sub-agent is undefined. Pick the level yourself from the review scope in `SCOPE_FILE`:

- **`low`** — small/simple scope: a handful of files, a small diff, or changes confined to docs/config/tests/formatting.
- **`medium`** — anything larger or touching actual logic (the default when in doubt).

Never go above `medium` (`high`/`xhigh`/`max` are out of scope for automated PR review — too slow and too noisy for an unattended tick). Capture its findings — do not act on its own posting behaviour (you are not posting).

Scope `/code-review` to the files listed in `SCOPE_FILE`. In DELTA mode, do NOT re-audit unchanged code for new issues, and do NOT review files outside the list (a rebase may have pulled them in).

## Step 2 — Classify findings

Map every finding to one severity:
- **BLOCKER** — security vulnerability, correctness/logic bug, data loss, breaking API change, CLAUDE.md correctness/safety rule violation, or a **house rule** below.
- **NIT** — everything else (style, naming, docs, dead code, missing tests, convention drift). List NITs even when approving.

**House rule — `Mint` in a method name is a BLOCKER on its own.** Any method or
function the PR **adds or renames** whose name carries the word `Mint` is a
BLOCKER with no other defect required. `Mint` is a stock LLM verb, not vocabulary
any codebase here uses: reaching for it means the author never settled what the
method actually does, so the name tells a reader nothing they can rely on. List it
like any other finding, and say what to do about it:

```json
{"severity": "BLOCKER", "text": "Naming: `MintCredentials` — `Mint` is not this codebase's vocabulary; rename to what the method actually does", "where": "src/Auth/TokenService.cs:31"}
```

Match on **name segments**, not raw substring — split the identifier on
camelCase/PascalCase boundaries and on `_`/`-`, and flag it when a segment is
exactly `mint`, case-insensitively. `MintToken`, `TryMintAsync`, and `mint_creds`
hit; `ConfirmIntent` and `Minutes` do not. Methods the PR only calls, or leaves
untouched, are out of scope — this is a rule about names the PR is introducing.

**Design check — cross-cutting concerns belong in the pipeline.** Flag a NIT when the PR repeats the
same concern in several controllers, handlers or consumers. Concerns include auth, tenant/account/caller
context, correlation, logging, validation, transactions, retries, auditing and context propagation,
whether repeated as code or as a scope (`using`/`Use(...)`, a static, an `AsyncLocal`).
Name the hook that should own it: middleware, a filter, a MediatR behaviour, a MassTransit filter,
a `DelegatingHandler` or an EF interceptor. Prefer a hook that already exists in the repo.
Skip the check when the value depends on data the handler loads, or when the rule is
business logic for one use case.

**Scope check** (skip if Step 0 recorded "no stated intent"): measure the diff against the stated intent. A scope problem is a finding like any other — tag it BLOCKER or NIT and list it:
- The PR does **not** address the linked issue's core ask, or implements something materially different/unrelated → **BLOCKER** (it won't actually resolve the issue it claims to). Prefix the text with `Scope:` and cite the issue, e.g. `Scope: issue #123 asks for X but the diff does Y / never touches X`.
- Partial coverage (most of the ask, minor part missing) or unrelated extra churn riding along → **NIT** (text `Scope: …`). Genuinely matching the intent adds no finding.
Judge against the stated ask only — do not invent acceptance criteria the issue/PR never stated.

**DELTA mode only — re-check the prior findings.** `PRIOR_FILE` is JSON:
`{"findings": [...]}`, the findings still live after the previous review, each
with its `severity`, `text` and (usually) `where`. For each one, check its status
at the current head (read the cited lines under `REVIEW_DIR`) and
record it in `prior` (Step 3) with exactly one status:

- `RESOLVED` — fixed at this head.
- `STILL OPEN` — still present.
- `REINTRODUCED` — was fixed, and this delta brings it back.

Keep each prior finding's **original** `severity`, `text` and `where` — do not
re-grade it. A prior finding that is still open goes in `prior` **only**; do not
repeat it in `findings`, or it counts twice.

If `PRIOR_FILE` instead carries a `legacy_body` (the previous review was posted
before findings were saved, so only its text survives), extract its numbered
findings — status-prefixed lines in a "Prior findings:" block keep their
original tag — and re-check each the same way. In FULL mode, or when there are no
prior findings, leave `prior` out.

## Step 3 — Write the findings file

Use the `Write` tool to write `FINDINGS_FILE`. It is the whole review: writing it
to disk is what lets the orchestrator post the correct review even if its context
is compacted after you return.

```json
{
  "findings": [
    {"severity": "BLOCKER", "text": "Correctness: null deref on an empty cart", "where": "src/Cart.cs:42"},
    {"severity": "NIT", "text": "Scope: the README example still shows the old flag"}
  ],
  "prior": [
    {"status": "RESOLVED", "severity": "BLOCKER", "text": "Unconditional write", "where": "src/Store.cs:266"},
    {"status": "STILL OPEN", "severity": "NIT", "text": "Rename `x`", "where": "src/Store.cs:88"}
  ]
}
```

- `findings` is required — `[]` when you found nothing. `prior` is DELTA only.
- `severity` is exactly `BLOCKER` or `NIT`; `status` is exactly `RESOLVED`,
  `STILL OPEN` or `REINTRODUCED`. Uppercase, spelled as shown.
- `text` is one line: the finding, with any `Scope:`/`Naming:` prefix from Step 2.
  No severity tag, no numbering, no location — the orchestrator adds those.
- `where` is `path:line` (or just `path`), optional; leave it out rather than
  guess.

The file is validated strictly: one malformed item — an unknown severity or
status, an empty `text`, a non-string `where`, or invalid JSON — rejects the
whole file, nothing is posted, and the PR is re-reviewed next tick.

You do not decide. The orchestrator counts every `BLOCKER` in `findings`, plus
every prior `BLOCKER` that is `STILL OPEN` or `REINTRODUCED`, and the verdict is
APPROVE exactly when that count is zero — so a core scope mismatch or a house-rule
hit blocks by being tagged `BLOCKER`. Whether an APPROVE posts as a GitHub
approval is the orchestrator's `--auto-approve` policy, not yours.

## Step 4 — Reply `DONE`

Your **entire response** must be exactly:

```
DONE
```

No summary, no findings, no preamble. The review lives in `FINDINGS_FILE`; the
orchestrator ignores your reply, which lands in its context on every PR of every
tick.

## Available tools

`Skill` (to run `/code-review`), `Write`, `Bash(gh api:*)`, `Bash(gh pr diff:*)`, `Bash(git -C <REVIEW_DIR> log:*)`, `Bash(git -C <REVIEW_DIR> blame:*)`, `Read`, `Glob`, `Grep`

## Working tree rules

The PR's head is already checked out in `REVIEW_DIR`; do not check anything out
yourself, there or anywhere else. The checkout each Bash call starts in may hold
the user's work: never run `git checkout`, `git switch`, `git reset`, `git clean`
or `git stash` in it. The orchestrator resets `REVIEW_DIR` after your
review.

Your job is **read-only review**: never `git commit`, `git push`, `git apply`, `git cherry-pick`, or `patch`. Inspect, don't mutate.
