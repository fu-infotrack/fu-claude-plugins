# PR Review Task

Your deliverable for PR #<PR> is written to **disk** (so it survives even if the
orchestrator's context is compacted after you return):

1. A review-body file at `BODY_FILE`, whose **first line** is a decision header
   `<!-- DECISION: APPROVE -->` (or `COMMENT`).
2. The decision token (`APPROVE` or `COMMENT`) written to `DECISION_FILE`.
3. A `DECISION:` line as the very last line of your response (a human-readable
   trace; the orchestrator reads the decision from the two files above, not this).

You do **NOT** post anything to GitHub yourself — the orchestrator posts the file you write. Running `/code-review` is only how you *gather* findings; it is NOT the end of your task. After `/code-review` returns, you MUST still do Steps 2–5. Do not stop after `/code-review`.

## Step 0 — Review context and PR intent

`STATE_FILE`, `PRIOR_FILE`, `BODY_FILE`, and `DECISION_FILE` are given to you as
absolute paths in your task prompt. Use them verbatim — do not construct your own
(they are namespaced per repo, so a hand-built path will be wrong).

1. Target repo (you run in the review clone, so gh detects it from cwd):
   `REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)`
   Use `<REPO>` to mean this value in every command below.
2. Current head commit:
   `gh pr view <PR> --repo <REPO> --json headRefOid --jq '.headRefOid'`
3. Read `STATE_FILE` if it exists. Line 1 = last reviewed commit, line 2 = last reviewed tree.
4. Decide review mode yourself:
   - No state file → **FULL review** (first time).
   - Otherwise compare last reviewed commit to head. Unchanged content → **FULL review** (human re-requested). Changed → **DELTA review**, `delta_base` = last reviewed commit.
5. Read the PR's stated intent so you can judge whether the diff actually delivers it:
   - `gh pr view <PR> --repo <REPO> --json title,body,closingIssuesReferences`
   - For each entry in `closingIssuesReferences` (issues the PR closes via "Closes/Fixes #N"), read it **including its comments**: `gh issue view <N> --repo <REPO> --json title,body,labels,comments`. Also scan the PR body for other `#<n>` mentions and read up to ~3 of them; ignore the rest (stay bounded).
   - **Read the issue comments, not just the body.** Product managers / maintainers often post the real detail there — clarifications, revised acceptance criteria, or scope cuts added after the issue was opened. Fold genuine requirement updates into the intent, and where a later clarifying comment conflicts with the original body, **the comment wins**. Ignore bot/status/CI chatter and side discussion; weight the issue author's and maintainers' clarifying comments.
   - Distil one line of **stated intent** (the issue's core ask, as refined by its clarifying comments, + the PR's own description). You compare the diff against it in Step 2. If there is no linked issue **and** the PR body is empty, record "no stated intent" and skip the scope check entirely (do not invent requirements).

The orchestrator only spawns you when there is work to do — do not re-check whether the PR should be skipped.

## Step 1 — Run `/code-review` to gather findings

Invoke the `/code-review` slash command on PR #<PR>. Capture its findings — do not act on its own posting behaviour (you are not posting).

For a DELTA review, scope `/code-review` to the PR's actual changed files (not the raw old-head→new-head diff, which includes rebased-in main commits):

```bash
# Files the PR adds relative to its base branch (the true PR scope)
PR_FILES=$(gh api repos/<REPO>/pulls/<PR>/files --jq ".[].filename")

# Files that changed between the last reviewed commit and the current head
DELTA_FILES=$(gh api repos/<REPO>/compare/<delta_base>...<head_commit> --jq ".files[].filename")

# Intersection: only files that are both in the PR and new/changed since last review
comm -12 <(echo "$PR_FILES" | sort) <(echo "$DELTA_FILES" | sort)
```

Review only the intersected file list. Do NOT re-audit unchanged code for new issues in delta mode, and do NOT review files that the PR did not touch (they may have been pulled in by a rebase).

## Step 2 — Classify findings and assemble the body

Map every finding to one severity:
- **BLOCKER** — security vulnerability, correctness/logic bug, data loss, breaking API change, or CLAUDE.md correctness/safety rule violation.
- **NIT** — everything else (style, naming, docs, dead code, missing tests, convention drift). List NITs even when approving.

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

**DELTA mode only** — read `PRIOR_FILE` (your previous review). For each prior finding, check its status at the current head (read cited lines via `gh api repos/<REPO>/contents/...`) and prepend a "Prior findings:" block listing each as RESOLVED / STILL OPEN / REINTRODUCED. If `PRIOR_FILE` is missing or empty, skip this block.

## Step 3 — Decide

- A STILL OPEN or REINTRODUCED prior BLOCKER counts as a current BLOCKER.
- A core scope mismatch (Step 2) is a BLOCKER like any other.
- APPROVE if zero BLOCKERs. COMMENT if one or more BLOCKERs.

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

The LAST line of your response must be exactly one of the following. (The
orchestrator reads your decision from `DECISION_FILE` / the body header, not from
this line — but still emit it as a human-readable trace.)

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
