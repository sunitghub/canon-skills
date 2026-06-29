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

For each PR, produce a one-block summary:

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

For each PR (Y or N), draft a comment summarising the outcome:

**Fix=Y template:**
```
Thanks for the PR. After review:

**Area:** <area>
**Findings:** <findings>
**Verdict:** Merging — filed as <ticket-id> to track implementation.
```

**Fix=N template:**
```
Thanks for the PR. After review:

**Area:** <area>
**Findings:** <findings>
**Verdict:** Not merging as-is — <one sentence on why / what would change the verdict>.
```

Show all drafts and ask:

> "Post these comments? (yes / edit first / skip)"

On **yes**: post each via:
```bash
gh pr comment <number> --repo sunitghub/canon-skills --body "<draft>"
```

On **edit first**: show the draft for the specific PR, accept the edit, reconfirm, then post.

On **skip**: do not post. Note it in chat.

## Constraints

- Never post a comment without explicit user approval.
- Never create a ticket without a Fix=Y decision from the user.
- Do not duplicate rows in the review file — match by PR number.
- Scope analysis to the PR diff only. Do not re-read the full canon codebase unless a specific file is directly relevant to a finding.
