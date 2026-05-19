---
name: impact-analysis
description: Pre-build risk assessment — rates audience, reversibility, blast radius, trigger paths, and cascade risk before any code is written
category: skills
tags: [planning, risk, impact, testing, sprint]
hidden: true
---

# Impact Analysis

Run before writing any code. Rates the change across five dimensions, surfaces hidden risks, and produces the test plan that gates sprint completion.

---

## When to run

Automatically during `sprint start` — not a separate invocation. The output feeds directly into `blueprint.md` and `acceptance.md`.

---

## Silent vs. surfaced

**Always rate all five dimensions.** Never skip the assessment.

**Surface the interrogation and ratings to the user only when at least one dimension is MEDIUM or HIGH.** For all-LOW changes, proceed silently — write the assessment to `blueprint.md` and move on without interrupting the sprint brief.

This keeps low-risk changes friction-free while ensuring nothing bypasses the check. The assessment is always written; it's only shown when it matters.

---

## Step 1 — Interrogate the request

Rate the five dimensions from context first. If any dimension looks MEDIUM or HIGH, ask the user the questions whose answers would confirm or change that rating. Do not ask questions whose answers can't move the needle.

**Questions that can change a rating:**
- Who can trigger this action, and from how many places in the UI or API? *(Trigger paths)*
- What happens if it runs twice? *(Reversibility, Blast radius)*
- Is there an undo path, or is this permanent? *(Reversibility)*
- Which other features, tables, or queues read the data this modifies? *(Cascade risk)*
- Does this touch anything that sends messages, emails, or notifications externally? *(Audience, Reversibility)*

**Ask only when relevant:**
- Does this action have a confirmation step — and is that step enforced server-side?
- Are there scheduled jobs or background workers that could race with this?
- Does this affect data that other teams or systems depend on?

If the user can't answer, note it as an open question in `HANDOFF.md` and treat that dimension conservatively (assume higher impact).

---

## Step 2 — Rate the five dimensions

| Dimension | HIGH | MEDIUM | LOW |
|---|---|---|---|
| **Audience** | Affects all users, all tenants, external systems, or is triggered automatically | Affects a user subset or a single tenant | Affects only the requesting user or internal tooling |
| **Reversibility** | Permanent: deletes, sends (email/SMS/webhook), financial writes, audit records | Recoverable with effort: DB update without backup, cache flush | Easily undone: config flag, feature toggle, draft state |
| **Blast radius** | Failure corrupts shared state or blocks other users | Failure is visible but contained to one session or record | Failure is silent or self-contained |
| **Trigger paths** | Multiple UI paths or API callers reach the same handler | One primary path + one secondary (e.g., direct URL) | Single, clearly bounded entry point |
| **Cascade risk** | Downstream consumers (jobs, queues, other tables, external APIs) react to this change | One downstream reader exists | No consumers — data is written and read in isolation |

Rate each dimension. Show your reasoning in one line per dimension.

---

## Step 3 — Required actions for HIGH ratings

Every HIGH-rated dimension triggers mandatory additions to the sprint:

| HIGH dimension | Required action |
|---|---|
| **Audience** | Add audit log requirement to acceptance.md. Identify all user roles who can invoke the action. |
| **Reversibility** | Define rollback procedure in blueprint.md. Add test: "verify rollback restores prior state." |
| **Blast radius** | Add test: "verify failure in this operation does not corrupt adjacent records or block other users." |
| **Trigger paths** | List every path (form action, API route, background job, CLI) that reaches the handler. Add test: "grep codebase for handler binding — expect exactly N matches." Add server-side auth check to acceptance criteria. |
| **Cascade risk** | List all downstream consumers. Add test per consumer: "verify consumer handles this change correctly." |

These are not optional. A sprint with any HIGH dimension that lacks the corresponding action cannot be closed.

---

## Step 4 — Write the impact block

Append to `blueprint.md`:

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

If test location is unclear, ask: "Where should these tests live — alongside the feature, in a dedicated test directory, or as a manual QA checklist?" Do not assume.

---

## Past sprint carryover

Before finalizing the impact assessment, scan `.tickets/` for closed tickets that modified any of the same files this sprint will touch.

For each match: add one regression test to `## Test Plan` confirming the prior behavior still holds. Note the source ticket ID.

This catches indirect regressions — where a new change silently breaks something fixed two sprints ago.

---

## Example — email send action

Request: "Add a button to send reminder emails to all pending managers."

**Interrogation output:**
- Trigger paths: found in actions panel (admin-only) — checking for secondary paths
- Idempotency: no guard — could send duplicates if clicked twice

**Ratings:**
| Dimension | Rating | Reason |
|---|---|---|
| Audience | HIGH | Sends external email to all pending managers — affects real inboxes |
| Reversibility | HIGH | Email cannot be unsent |
| Blast radius | MEDIUM | Failure affects only this send batch, not shared state |
| Trigger paths | HIGH | Must verify exactly one handler binding exists across all templates |
| Cascade risk | LOW | No downstream queue or system reads the send result |

**Required actions:**
- Audit log: record who triggered, timestamp, sent/skipped/failed counts
- Rollback: N/A for email sends — document that the action is irreversible in the UI
- Trigger path test: grep templates for handler binding — expect exactly 1
- Server-side auth: verify handler checks authorization independently of UI visibility
