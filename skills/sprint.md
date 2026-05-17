---
name: sprint
description: Full dev workflow — plan, build, and ship focused units of work with acceptance-criteria-gated delivery
summary: Full dev workflow: plan → build → ship. Two commands cover everything.
category: dev
tags: [workflow, planning, quality, tickets, orchestration]
depends: [wrapup, capture, ticket, handoff]
---

@/Users/Sunit/Developer/canon/skills/wrapup.md
@/Users/Sunit/Developer/canon/skills/capture.md

# Sprint

Plan, build, and ship focused units of work with acceptance-criteria-gated delivery.
This skill embeds tkt, wrapup, and capture — you only need two commands:

| Command | When |
|---|---|
| `sprint start` | Before writing any code |
| `sprint complete` | When you believe the work is done |

`capture` runs automatically between them — no invocation needed.

---

## sprint start

**Trigger:** "sprint start", "start a sprint for X", "start working on X", "let's work on X"

1. **Ticket.** If no active ticket: `tkt create "<title>"`. If tkt is not in use, create
   `planning/sprints/<slug>/` instead. Run `tkt start <id>` (or note the slug as active).

2. **Planning files.** Create in `.tickets/<id>/` (or `planning/sprints/<slug>/` if no tkt):
   - `blueprint.md` — files to inspect, files to create/modify, step-by-step build plan
   - `acceptance.md` — specific, binary conditions that define "done"
   - If these already exist: read them and proceed without recreating.

3. **Context.** Read in order:
   - `DECISIONS.md` at repo root — create with empty log table if absent
   - `HANDOFF.md` — current state and discoveries
   - Active sprint files

4. **Sprint brief.** Before writing any code, produce:
   - What this sprint accomplishes (one sentence)
   - Files expected to be created or modified
   - Acceptance criteria (verbatim from acceptance.md)
   - Any constraints from DECISIONS.md that apply
   - Ambiguities or blockers

5. **Wait for explicit approval.** Do not write application code until the user confirms.

---

## sprint complete

**Trigger:** "sprint complete", "complete the sprint", "approve", "ship it", "approve `<id>`"

Do not accept the user's claim that work is done. Verify it.

1. **Wrapup.** Run the pipeline defined above (code-simplifier → code-reviewer →
   security-review) on all files modified since sprint start. Apply skip rules as defined.

2. **Acceptance check.** Review each item in `acceptance.md`:
   - ✓ met | ✗ not met | ? uncertain
   - If any ✗: report what is missing. Do not close the ticket. Stop here.
   - Proceed only when all criteria are ✓ or explicitly waived by the user.

3. **DECISIONS.md.** Append any durable decisions made during this sprint — non-obvious
   architectural choices, explicit tradeoffs, out-of-scope calls. One row per decision.
   Write the WHY, not the what. Skip if no new decisions were made.

4. **HANDOFF.md.** Update `## Next Steps` with any follow-up work.

5. **Close.** Run `tkt close <id>` (or mark sprint slug complete).

6. **Report.** One paragraph: what shipped, any waived criteria and why, follow-up recorded.

---

## Planning files

With tkt:
```
.tickets/<id>/
  ticket.md        ← tkt-managed
  blueprint.md     ← implementation plan
  acceptance.md    ← definition of done
```

Without tkt:
```
planning/sprints/<slug>/
  blueprint.md
  acceptance.md
```

---

## DECISIONS.md

Repo root. Records durable choices future sprints must respect. Not a session log.

```markdown
# Decisions

| Date | Decision | Reason |
|---|---|---|
| 2026-05-17 | Amounts stored as integer cents | Avoid float precision bugs |
```

Write a decision when a non-obvious choice is made that would surprise a future agent.
Never write decisions obvious from reading the code.
