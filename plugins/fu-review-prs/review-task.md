# PR Review Task

Your deliverable for PR #<PR> is written to **disk** (so it survives even if the
orchestrator's context is compacted after you return):

1. A review-body file at `BODY_FILE`, whose **first line** is a decision header
   `<!-- DECISION: APPROVE -->` (or `COMMENT`).
2. The decision token (`APPROVE` or `COMMENT`) written to `DECISION_FILE`.
3. A response that is **exactly one line**, `DECISION: APPROVE` or
   `DECISION: COMMENT` — nothing else (the orchestrator reads the decision from the
   two files above; your reply only costs it context).

You do **NOT** post anything to GitHub yourself — the orchestrator posts the file you write. Running `/code-review` is only how you *gather* findings; it is NOT the end of your task. After `/code-review` returns, you MUST still do Steps 2–5. Do not stop after `/code-review`.

## Step 0 — Review context and PR intent

`SCOPE_FILE`, `PRIOR_FILE`, `BODY_FILE`, and `DECISION_FILE` are given to you as
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
   - `gh pr view <PR> --repo <REPO> --json title,body,closingIssuesReferences`
   - For each entry in `closingIssuesReferences` (issues the PR closes via "Closes/Fixes #N"), read it **including its comments**: `gh issue view <N> --repo <REPO> --json title,body,labels,comments`. Also scan the PR body for other `#<n>` mentions and read up to ~3 of them; ignore the rest (stay bounded).
   - **Read the issue comments, not just the body.** Product managers / maintainers often post the real detail there — clarifications, revised acceptance criteria, or scope cuts added after the issue was opened. Fold genuine requirement updates into the intent, and where a later clarifying comment conflicts with the original body, **the comment wins**. Ignore bot/status/CI chatter and side discussion; weight the issue author's and maintainers' clarifying comments.
   - Distil one line of **stated intent** (the issue's core ask, as refined by its clarifying comments, + the PR's own description). You compare the diff against it in Step 2. If there is no linked issue **and** the PR body is empty, record "no stated intent" and skip the scope check entirely (do not invent requirements). A body holding **only HTML comments** counts as empty — `fu-dev-guards` stamps `<!-- claude-session: <uuid> -->` into every PR body, so a genuinely description-less PR is no longer literally empty. Never distil intent from a marker comment.

The orchestrator only spawns you when there is work to do — do not re-check whether the PR should be skipped.

## Step 1 — Run `/code-review` to gather findings

Invoke the `/code-review` slash command on PR #<PR>, always with an explicit level — `low` or `medium` — never bare `/code-review`: without an explicit level it reuses whatever level was last typed in the invoking context, which for a fresh sub-agent is undefined. Pick the level yourself from the review scope in `SCOPE_FILE`:

- **`low`** — small/simple scope: a handful of files, a small diff, or changes confined to docs/config/tests/formatting.
- **`medium`** — anything larger or touching actual logic (the default when in doubt).

Never go above `medium` (`high`/`xhigh`/`max` are out of scope for automated PR review — too slow and too noisy for an unattended tick). Capture its findings — do not act on its own posting behaviour (you are not posting).

Scope `/code-review` to the files listed in `SCOPE_FILE`. In DELTA mode, do NOT re-audit unchanged code for new issues, and do NOT review files outside the list (a rebase may have pulled them in).

## Step 2 — Classify findings and assemble the body

Map every finding to one severity:
- **BLOCKER** — security vulnerability, correctness/logic bug, data loss, breaking API change, CLAUDE.md correctness/safety rule violation, or a **house rule** below.
- **NIT** — everything else (style, naming, docs, dead code, missing tests, convention drift). List NITs even when approving.

**House rule — `Mint` in a method name is a BLOCKER on its own.** Any method or
function the PR **adds or renames** whose name carries the word `Mint` is a
BLOCKER with no other defect required. `Mint` is a stock LLM verb, not vocabulary
any codebase here uses: reaching for it means the author never settled what the
method actually does, so the name tells a reader nothing they can rely on. List it
like any other finding, and say what to do about it:

```
1. [BLOCKER] Naming: `MintCredentials` — `Mint` is not this codebase's vocabulary; rename to what the method actually does — `src/Auth/TokenService.cs:31`
```

Match on **name segments**, not raw substring — split the identifier on
camelCase/PascalCase boundaries and on `_`/`-`, and flag it when a segment is
exactly `mint`, case-insensitively. `MintToken`, `TryMintAsync`, and `mint_creds`
hit; `ConfirmIntent` and `Minutes` do not. Methods the PR only calls, or leaves
untouched, are out of scope — this is a rule about names the PR is introducing.

**Scope check** (skip if Step 0 recorded "no stated intent"): measure the diff against the stated intent. A scope problem is a finding like any other — tag it BLOCKER or NIT and list it:
- The PR does **not** address the linked issue's core ask, or implements something materially different/unrelated → **BLOCKER** (it won't actually resolve the issue it claims to). Prefix the description with `Scope:` and cite the issue, e.g. `[BLOCKER] Scope: issue #123 asks for X but the diff does Y / never touches X`.
- Partial coverage (most of the ask, minor part missing) or unrelated extra churn riding along → **NIT** (`[NIT] Scope: …`). Genuinely matching the intent adds no finding.
Judge against the stated ask only — do not invent acceptance criteria the issue/PR never stated.

Assemble the review body in this format:

```
### Code review — PR #<PR>
Found N issues:
1. [BLOCKER] Description — `path/to/file.cs:42`
2. [NIT] Description — `path/to/file.cs:88`
```

**DELTA mode only** — read `PRIOR_FILE` (your previous review). For each prior finding, check its status at the current head (read cited lines via `gh api repos/<REPO>/contents/...`) and prepend a "Prior findings:" block. If `PRIOR_FILE` is missing or empty, skip this block.

Each prior-findings line puts the status **first, before the severity tag**, and
repeats the finding's **original** tag:

```
Prior findings:
1. RESOLVED — [BLOCKER] Description — `path/to/file.cs:42`
2. STILL OPEN — [NIT] Description — `path/to/file.cs:88`
3. REINTRODUCED — [BLOCKER] Description — `path/to/file.cs:12`
```

Status is exactly one of `RESOLVED`, `STILL OPEN`, `REINTRODUCED`. **That order is
a wire format, not cosmetics.** The orchestrator counts current blockers off these
lines and recognises a fixed one only by `RESOLVED` sitting *before* the
`[BLOCKER]` tag on the same line. Put the status anywhere else — a trailing
`(RESOLVED)`, a separate `Status:` line — and a blocker you just confirmed fixed
gets notified as live, which is the exact false alarm this shape prevents.

## Step 3 — Decide

- A STILL OPEN or REINTRODUCED prior BLOCKER counts as a current BLOCKER.
- A core scope mismatch (Step 2) is a BLOCKER like any other.
- A house-rule hit (Step 2 — a `Mint`-named method) is a BLOCKER like any other.
- APPROVE if zero BLOCKERs. COMMENT if one or more BLOCKERs.

`APPROVE` here means exactly "I found zero BLOCKERs" — it is **not** a promise that
GitHub receives an approval. The orchestrator posts approvals only when the tick was
started with `--auto-approve`; otherwise it posts your findings as a COMMENT. Report
your honest verdict and leave that policy to the orchestrator.

## Step 4 — Write the body file and the decision sidecar

Use the `Write` tool to write **both** files. Writing the decision to disk (both
places) is what lets the orchestrator post the correct review even if its context
is compacted after you return — do not skip either.

1. **`BODY_FILE`** — a decision header as the very first line, then the assembled
   review body from Step 2:

   ```
   <!-- DECISION: APPROVE -->
   ### Code review — PR #<PR>
   Found N issues:
   ...
   ```

   Use `APPROVE` or `COMMENT` to match your Step 3 decision. Body only after the
   header — no marker, no footer; the orchestrator adds those and strips the header
   line before posting. If you found no issues (clean APPROVE), still write the
   formatted body with `Found 0 issues`.

2. **`DECISION_FILE`** — a single line containing just `APPROVE` or `COMMENT` (the
   same decision). This sidecar is the authoritative source the orchestrator reads;
   the body header is its backup.

## Step 5 — Emit the decision sentinel

Your **entire response** must be exactly one of the following lines — no summary,
no findings, no preamble. The review lives in `BODY_FILE`; the orchestrator reads
your decision from `DECISION_FILE` / the body header and ignores your reply, which
lands in its context on every PR of every tick.

```
DECISION: APPROVE
```
```
DECISION: COMMENT
```

## Available tools

`SlashCommand` (to run `/code-review`), `Write`, `Bash(gh:*)`, `Bash(git log:*)`, `Bash(git blame:*)`, `Read`, `Glob`, `Grep`

## Working tree rules

`gh pr checkout <PR>` is allowed and encouraged for reading files at the PR's head — you do **not** need to restore the tree afterwards. The orchestrator force-resets the dedicated clone back to a clean `main` (discarding tracked changes and untracked files) after your review, so leaving it on the PR branch is fine.

Your job is **read-only review**: never `git commit`, `git push`, `git apply`, `git cherry-pick`, or `patch`. Inspect, don't mutate.
