---
name: sprint
description: Full dev workflow — plan, build, and ship focused units of work with acceptance-criteria-gated delivery
summary: plan → build → ship. Grills gray areas, rates impact across five dimensions, generates a test plan, and awaits approval. Approved plan persists to plan.md for compaction resilience. sprint complete verifies all tests passed before closing.
category: dev
tags: [workflow, planning, quality, tickets, orchestration]
depends: [wrapup, capture, ticket, handoff, impact-analysis, orient]
---

@/Users/Sunit/Developer/canon/skills/wrapup.md
@/Users/Sunit/Developer/canon/skills/capture.md
@/Users/Sunit/Developer/canon/skills/impact-analysis.md
@/Users/Sunit/Developer/canon/skills/orient.md

# Sprint

Plan, build, and ship focused units of work with acceptance-criteria-gated delivery.
This skill embeds tkt, wrapup, and capture — you only need two commands:

| Command | When |
|---|---|
| `sprint start` | Any dev request — automatic unless the change is trivially mechanical |
| `sprint complete` | When you believe the work is done |

`capture` runs automatically between them — no invocation needed.

---

## Default mode

Sprint is the default workflow for any substantive dev request. Route through `sprint start` automatically when the user asks to add, fix, update, refactor, implement, debug, or build anything — without waiting for the explicit phrase "sprint start".

**Skip sprint and proceed directly only when:**
- The request is a question or explanation ("what does X do?", "explain Y")
- The change is a single line or trivially mechanical (typo, rename, one-word config change)
- The user explicitly says to skip it ("just fix it", "quick change")

When in doubt, use sprint. The approval gate is low friction — it takes one "yes" to proceed.

Sprint isn't code-only — it works equally well for docs, config, and planning file updates. The wrapup pipeline skips steps that don't apply (e.g., simplifier and security-review are both skipped for docs-only changes).

---

## sprint start

**Trigger:** "sprint start", "start a sprint for X", "let's work on X" — or any request to add, fix, update, debug, implement, or build something that isn't explicitly trivial

1. **Ticket.** If no active ticket: `tkt create "<title>"`. If tkt is not in use, create
   `planning/sprints/<slug>/` instead. Run `tkt start <id>` (or note the slug as active).

2. **Planning files.** Create in `.tickets/<id>/` (or `planning/sprints/<slug>/` if no tkt):
   - `blueprint.md` — files to inspect, files to create/modify, step-by-step build plan
   - `acceptance.md` — specific, binary conditions that define "done"
   - If these already exist: read them and proceed without recreating.

3. **Context.** Read in order:
   - `DECISIONS.md` at repo root — create with empty log table if absent
   - `HANDOFF.md` — create from template if absent, otherwise read current state and discoveries
   - Active sprint files
   - Closed tickets in `.tickets/` that touched files this sprint will modify — note any whose behavior must still hold (used in Step 5 regression tests)

4. **Orient.** Run the orient sub-skill: survey the subsystem around the planned files, trace dependencies, and flag any non-obvious relationships. Appends `## Subsystem Map` to `blueprint.md`. This runs automatically — no user action needed. Findings feed directly into the Grill step.

5. **Grill.** Surface implementation gray areas — decisions that could reasonably go several ways and would materially change what gets built.

   - Analyze the request and identify up to 5 gray areas (API shape, data model, UI behavior, error handling approach, integration pattern, scope boundary, etc.)
   - **If no genuine gray areas exist:** skip silently and proceed to impact analysis.
   - **If gray areas exist:** present them numbered. For each: state the decision to be made and the tradeoffs. Wait for the user to resolve all of them before proceeding.
   - Scope guardrail: grill clarifies HOW to implement what is already scoped. It does not add scope or renegotiate what is being built.
   - Log each resolved gray area under `## Grill` in `blueprint.md`.

6. **Impact analysis.** Before producing the sprint brief, run the full impact analysis process defined in the impact-analysis skill:
   - Interrogate the request — ask every question whose answer changes the risk profile. Do not skip this even if the request seems straightforward.
   - Rate all five dimensions (Audience, Reversibility, Blast radius, Trigger paths, Cascade risk).
   - For every HIGH rating: add the required action to `blueprint.md` and the required test to `acceptance.md ## Test Plan`.
   - Past sprint carryover: add regression tests for any closed tickets that touched the same files.
   - Write the `## Impact Assessment` block to `blueprint.md` and `## Test Plan` to `acceptance.md`.
   - If test location is unclear, ask the user before proceeding.

7. **Sprint brief.** After impact analysis, produce:
   - What this sprint accomplishes (one sentence)
   - Files expected to be created or modified
   - Impact summary: overall rating + any HIGH dimensions with their required actions called out
   - Acceptance criteria (verbatim from acceptance.md)
   - Test plan (verbatim from acceptance.md ## Test Plan)
   - Any constraints from DECISIONS.md that apply
   - Open questions or blockers still unresolved

8. **Wait for explicit approval.** Do not write application code until the user confirms. On approval, write `plan.md` to `.tickets/<id>/` (or `planning/sprints/<slug>/`) with:
   - Timestamp and ticket ID
   - Grill resolutions (if any)
   - Full approved sprint brief (verbatim: objective, files, impact summary, acceptance criteria, test plan)

   `plan.md` is the compaction-resilient record. If context is reset or compacted mid-sprint, re-read `plan.md` before continuing — it is the source of truth for what was approved.

---

## sprint complete

**Trigger:** "sprint complete", "complete the sprint", "approve", "ship it", "approve `<id>`"

Do not accept the user's claim that work is done. Verify it.

1. **Wrapup.** Run the pipeline defined above (code-simplifier → code-reviewer →
   security-review) on all files modified since sprint start. Apply skip rules as defined.

2. **Test verification.** Review each item in `acceptance.md ## Test Plan`:
   - ✓ passed | ✗ failed | ? not run
   - If any ✗ or ?: report which tests did not pass. Do not close the ticket. Stop here.
   - This includes all impact tests and regression tests, not just functional tests.
   - Confirm test results are documented in `acceptance.md` (pass/fail per item, date run).
   - Proceed only when all tests are ✓ or explicitly waived by the user with a documented reason.

3. **Acceptance check.** Review each item in `acceptance.md`:
   - ✓ met | ✗ not met | ? uncertain
   - If any ✗: report what is missing. Do not close the ticket. Stop here.
   - Proceed only when all criteria are ✓ or explicitly waived by the user.

4. **DECISIONS.md.** Append any durable decisions made during this sprint — non-obvious
   architectural choices, explicit tradeoffs, out-of-scope calls. One row per decision.
   Write the WHY, not the what. Skip if no new decisions were made.

5. **Conventions.** While context is fresh, check if any convention-level learnings emerged — patterns, naming norms, non-obvious file relationships, gotchas — that would help a future agent working in this area. These are distinct from decisions: a decision is "we chose X"; a convention is "in this codebase, X always lives next to Y" or "never touch Z without also updating W."
   - If yes: propose the addition (one or two lines) and the target file (`AGENTS.md`, `CLAUDE.md`, or a subdirectory `CLAUDE.md` if one exists). Ask the user to confirm before writing.
   - If no new conventions emerged: skip silently.

6. **HANDOFF.md.** Update `## Next Steps` with any follow-up work.

7. **Close.** Run `tkt close <id>` (or mark sprint slug complete).

8. **Report.** One paragraph: what shipped, test results summary, any waived criteria and why, follow-up recorded.

---

## Planning files

With tkt:
```
.tickets/<id>/
  ticket.md        ← tkt-managed
  blueprint.md     ← implementation plan (includes Grill resolutions + Impact Assessment)
  acceptance.md    ← definition of done + test plan
  plan.md          ← approved sprint brief; written on approval, re-read after compaction
```

Without tkt:
```
planning/sprints/<slug>/
  blueprint.md
  acceptance.md
  plan.md
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
