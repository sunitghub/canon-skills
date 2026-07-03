---
name: pr-review
description: Reviews open PRs on sunitghub/canon-skills — fetches diffs, presents findings, updates PRs/canon-skills-pr-review.md, creates tickets for Fix=Y PRs, and posts approved comments. Use when the user asks to review canon-skills PRs or check what's open on canon-skills.
category: dev
tags: [github, prs, review, workflow]
hidden: true
---

# PR Review

Reviews open PRs on `sunitghub/canon-skills`. Human decides Fix Y/N — skill handles mechanics.

## Steps

### 1. Fetch open PRs

```bash
gh pr list --repo sunitghub/canon-skills --state open \
  --json number,title,body,url,createdAt
```

If no open PRs: report "No open PRs on sunitghub/canon-skills." and stop.

### 2. Read each diff

For each open PR:

```bash
gh pr diff <number> --repo sunitghub/canon-skills
```

### 3. Read current review file

Read `PRs/canon-skills-pr-review.md`. Extract the PR numbers already in the table (first column) — these are existing entries to update in place, not duplicate.

### 4. Analyse and present

For each finding you'd otherwise raise, score it 0-100 before including it:

- **0** — false positive: doesn't hold up, or a pre-existing issue not introduced by this PR.
- **25** — unverified or a stylistic nit not called out by any convention in this repo.
- **50** — verified real, but a minor nitpick, low-impact in practice.
- **75** — verified real and important: will affect functionality, correctness, or maintainability in practice.
- **100** — certain and will be hit frequently in practice.

Drop anything scoring below 80 — do not include it in the findings block below. Check each candidate finding against this false-positive list before scoring:

- Pre-existing issue, not introduced by this PR
- Looks like a bug but isn't
- Pedantic nitpick a senior engineer wouldn't raise
- Something a linter, typechecker, or compiler would already catch
- Silenced via an explicit lint-ignore comment
- On a line the PR didn't modify

For each PR, produce a one-block summary from the findings that survive the filter:

```
PR #<n> — <title>
Area:     <one of: Tooling / DX / Sprint / MCP / Docs / Meta>
Findings: <2–4 sentences: what it does, what's good, what's risky or wrong>
Recommend: Fix Y / Fix N — <one-line reason>
```

Present all PRs, then ask:

> "Fix Y/N for each? I'll wait for your call before updating the review file or creating tickets."

### 5. Receive decisions

Wait for the user to confirm Y/N per PR. Accept any clear format ("Y on #2, N on #3", "#2 yes", etc.). Do not proceed until all open PRs have a decision.

### 6. Update PRs/canon-skills-pr-review.md

**Table columns (preserve existing order):**
`| PR | Title | Area | Findings | Verdict | Opened | Reviewed |`

**Date format:**
- `Opened`: PR `createdAt` converted to Central time and formatted as `MM/DD/YYYY`.
- `Reviewed`: date this review pass updated the row, formatted as `MM/DD/YYYY`.

- **Existing entry (PR number already in table):** update the row in place — replace Findings, Verdict, and Reviewed with the current analysis/date. Preserve Opened unless it is missing or in an older format; normalize old Opened values to `MM/DD/YYYY`. Do not add a new row.
- **New entry:** insert a new row at the top of the table (below the header), above existing rows. Set Verdict to `Merge` (Fix=Y) or `No` (Fix=N), Opened from `createdAt`, and Reviewed to today's review date.
- Escape any `|` inside cell text as `\|`.

### 7. Create tickets for Fix=Y PRs

For each PR where the user confirmed Fix=Y, run:

```bash
tkt create "implement: <short title referencing PR #n>"
```

Then open the created ticket's `ticket.md` and append to the description body:

```
Source: <PR URL>
Area: <area>
Findings: <findings summary>
```

Report the ticket ID created for each PR.

### 8. Draft and post comments

For each PR (Y or N), draft a comment summarising the outcome. Cite each specific finding with a full-SHA blob link, not just prose — this lets the PR author jump straight to the flagged code:

```
https://github.com/sunitghub/canon-skills/blob/<full-sha>/<path>#L<start>-L<end>
```

Fetch the full head SHA for the link (do not use `git rev-parse` or any local shell substitution — the link must render as literal markdown, and this flow never checks out the PR branch):

```bash
gh pr view <number> --repo sunitghub/canon-skills --json headRefOid -q .headRefOid
```

Include at least 1 line of context before and after the flagged line in the range (e.g. a finding on line 12 links `#L11-L13`).

**Fix=Y template:**
```
Thanks for the PR. After review:

**Area:** <area>
**Findings:** <findings, with a blob link per cited issue>
**Verdict:** Merging — filed as <ticket-id> to track implementation.
```

**Fix=N template:**
```
Thanks for the PR. After review:

**Area:** <area>
**Findings:** <findings, with a blob link per cited issue>
**Verdict:** Not merging as-is — <one sentence on why / what would change the verdict>.
```

Show all drafts and ask:

> "Post these comments? (yes / edit first / skip)"

On **yes**: immediately before posting each comment, re-check the PR is still eligible — it may have been closed, merged, or converted to draft since step 1:

```bash
gh pr view <number> --repo sunitghub/canon-skills --json state,isDraft
```

If `state` is no longer `OPEN` or `isDraft` is now `true`, skip posting that comment and note it in chat instead. Otherwise post via:
```bash
gh pr comment <number> --repo sunitghub/canon-skills --body "<draft>"
```

On **edit first**: show the draft for the specific PR, accept the edit, reconfirm, then post (with the same eligibility re-check).

On **skip**: do not post. Note it in chat.

## Constraints

- Never post a comment without explicit user approval.
- Never create a ticket without a Fix=Y decision from the user.
- Do not duplicate rows in the review file — match by PR number.
- Scope analysis to the PR diff only. Do not re-read the full canon codebase unless a specific file is directly relevant to a finding.
