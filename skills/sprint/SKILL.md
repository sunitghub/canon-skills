---
name: sprint
description: Manages the sprint workflow for focused changes. Use when asked to add, fix, update, implement, debug, or build anything.
category: dev
tags: [workflow, planning, quality, tickets, orchestration]
depends: []
---

# Sprint

CLI-backed commands:

| Command | When |
|---|---|
| `sprint start` | Any normal or high-risk dev request |
| `sprint complete` | When you believe the work is done |

The `sprint` CLI owns deterministic workflow state: ticket creation, active
ticket tracking, context file creation, and close validation. The agent owns
sprint doc creation, orientation, gray-area resolution, impact analysis,
implementation, review, and test judgment.

## Dispatch purposes

Tag every sub-agent dispatch in sprint flows with exactly one purpose:
- `implement` — build or modify the approved sprint scope.
- `review` — independently evaluate completed work, risks, or acceptance evidence.
- `explore` — read and map a subsystem before implementation decisions.

## Workflow tiers

Choose the lightest tier that still protects the work.

### Trivial

Use no sprint when:
- The request is a question or explanation
- The change is a single line or trivially mechanical
- The user explicitly says to skip it ("just fix it", "quick change")

Work directly, then report verification.

### Normal

Default for focused, reversible product/docs/code changes that affect a small surface.

Run `sprint start`, create `acceptance.md` and `plan.md`, then build after approval. Keep plan.md brief: files, approach, known constraints, and test plan.

Skip full orient, grill, and impact-analysis unless the local code is unclear or a high-risk trigger appears.

### High-risk

Use the full planning pipeline when any condition applies:
- Security-sensitive behavior changes: auth, authorization, secrets, sessions, crypto, external input, file writes, API endpoints
- Irreversible or hard-to-reverse operations: deletes, sends, payments, migrations, data rewrites, publishes, deploys
- Broad audience or shared-state blast radius
- Multiple UI/API/job trigger paths reach the same behavior
- Downstream consumers react to the changed data or event
- The implementation has genuine gray areas that would materially change the design

High-risk sprints run orient, grill, impact-analysis, required mitigation tests, and full wrapup.

## sprint start

Read `skills/sprint/reference/start.md` for the full protocol (steps 1-10).

## sprint complete

Read `skills/sprint/reference/complete.md` for the full protocol (trigger, confirmation, steps 1-8).

## Planning files

Canonical layout:
```
.tickets/<id>/
  ticket.md        ← tkt-managed; never edit status directly — valid values: open, in_progress, closed, cancelled
  acceptance.md    ← definition of done + test plan
  plan.md          ← approach, decisions, grill/impact sections for high-risk; skeleton created at sprint start, sign-off block added on approval, re-read after compaction
  research.md      ← optional; high-risk and brownfield sprints only; objective truth compression
  summary.md       ← plan-vs-actual table; written at sprint complete
```

## DECISIONS.md

Repo root. Records durable choices future sprints must respect. Not a session log. Write non-obvious choices only. Skip decisions obvious from code.
