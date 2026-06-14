---
name: impact-analysis
description: Rate audience, reversibility, blast radius, trigger paths, and cascade risk before coding
category: dev
tags: [planning, risk, impact, testing, sprint]
hidden: true
---

# Impact Analysis

Runs in `sprint start`. Writes to `plan.md` and `acceptance.md`.

Always present the rating table and required actions before proceeding — even when all dimensions are LOW. For all-LOW: "Impact assessment: all dimensions LOW — no required mitigations." User sees every assessment; there is no silent path.

## Step 1 — Interrogate the request

Rate from context first. For MEDIUM or HIGH dimensions, ask only questions whose answers can change the rating.

Useful questions:
- Who can trigger this action, and from how many places in the UI or API? *(Trigger paths)*
- What happens if it runs twice? *(Reversibility, Blast radius)*
- Is there an undo path, or is this permanent? *(Reversibility)*
- Which other features, tables, or queues read the data this modifies? *(Cascade risk)*
- Does this touch anything that sends messages, emails, or notifications externally? *(Audience, Reversibility)*

Ask only when relevant:
- Does this action have a confirmation step — and is that step enforced server-side?
- Are there scheduled jobs or background workers that could race with this?
- Does this affect data that other teams or systems depend on?

If unanswered, note it in `HANDOFF.md` and rate conservatively.

## Step 2 — Rate the five dimensions

| Dimension | HIGH | MEDIUM | LOW |
|---|---|---|---|
| **Audience** | Affects all users, all tenants, external systems, or is triggered automatically | Affects a user subset or a single tenant | Affects only the requesting user or internal tooling |
| **Reversibility** | Permanent: deletes, sends (email/SMS/webhook), financial writes, audit records | Recoverable with effort: DB update without backup, cache flush | Easily undone: config flag, feature toggle, draft state |
| **Blast radius** | Failure corrupts shared state or blocks other users | Failure is visible but contained to one session or record | Failure is silent or self-contained |
| **Trigger paths** | Multiple UI paths or API callers reach the same handler | One primary path + one secondary (e.g., direct URL) | Single, clearly bounded entry point |
| **Cascade risk** | Downstream consumers (jobs, queues, other tables, external APIs) react to this change | One downstream reader exists | No consumers — data is written and read in isolation |

Show one-line reasoning per dimension.

## Step 3 — Required actions for HIGH ratings

Every HIGH rating adds sprint work:

| HIGH dimension | Required action |
|---|---|
| **Audience** | Add audit log requirement to acceptance.md. Identify all user roles who can invoke the action. |
| **Reversibility** | Define rollback procedure in plan.md. Add test: "verify rollback restores prior state." |
| **Blast radius** | Add test: "verify failure in this operation does not corrupt adjacent records or block other users." |
| **Trigger paths** | List every path (form action, API route, background job, CLI) that reaches the handler. Add test: "grep codebase for handler binding — expect exactly N matches." Add server-side auth check to acceptance criteria. |
| **Cascade risk** | List all downstream consumers. Add test per consumer: "verify consumer handles this change correctly." |

HIGH dimensions cannot close without the matching action.

## Step 4 — Human checkpoint

Require a human checkpoint when any condition applies:
- Any impact dimension is HIGH
- The change deletes, sends, migrates, publishes, deploys, charges, or modifies external/shared state
- Rollback is unclear
- Test location is unclear
- The agent cannot prove the old/new behavior boundary

Record the checkpoint in `plan.md`:
- Decision needed: <specific approval or boundary>
- Human resolution: <approved / rejected / narrowed scope / deferred>
- Approved autonomy: plan only / implement only / implement + run tests / no autonomous execution

For HIGH-impact work that needs explicit human approval, add this item to `acceptance.md ## Test Plan`:

```markdown
- [ ] Human approval recorded for HIGH-impact change before implementation
```

## Step 5 — Write the impact block

Append to `plan.md`:

```markdown
## Impact Assessment

| Dimension | Rating | Reason |
|---|---|---|
| Audience | HIGH / MEDIUM / LOW | <one line> |
| Reversibility | HIGH / MEDIUM / LOW | <one line> |
| Blast radius | HIGH / MEDIUM / LOW | <one line> |
| Trigger paths | HIGH / MEDIUM / LOW | <one line> |
| Cascade risk | HIGH / MEDIUM / LOW | <one line> |

**Overall: HIGH / MEDIUM / LOW** — <one sentence summary>

### Required actions
- <list from Step 3, or "None — no HIGH dimensions">

### Open questions
- <unresolved ambiguities, or "None">

### Human checkpoint
- Required: yes / no
- Decision needed: <specific approval or boundary, or "None">
- Human resolution: <approved / rejected / narrowed scope / deferred, or "None">
- Approved autonomy: plan only / implement only / implement + run tests / no autonomous execution / not applicable
```

Append to `acceptance.md` under `## Test Plan`:

```markdown
## Test Plan

> All tests must pass before sprint complete is accepted.

### Functional tests
- [ ] <binary pass/fail test for each acceptance criterion>

### Impact tests
- [ ] <one test per HIGH-rated dimension, per Step 3>

### Regression tests
- [ ] <tests for any prior sprint that touched the same files — see Past sprint carryover>

**Test location:** <path, or ask the user if unclear>
```

Ask before proceeding if test location is unclear.

## Past sprint carryover

Scan `.tickets/` for closed tickets that modified files this sprint will touch. Add one regression test per match and note the source ticket ID.
