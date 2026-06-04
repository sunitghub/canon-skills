---
name: sprint
description: Plan, build, and ship focused work with acceptance-gated delivery
summary: The sprint CLI creates/starts tickets, tracks active state, and validates close. The agent creates sprint docs, maps the subsystem, resolves gray areas, rates impact, builds, tests, and runs wrapup.
category: dev
tags: [workflow, planning, quality, tickets, orchestration]
depends: [wrapup, capture, ticket, handoff, impact-analysis, orient]
---

@./wrapup.md
@./capture.md
@./impact-analysis.md
@./orient.md

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

---

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

Run `sprint start`, create `acceptance.md`, `blueprint.md`, and `plan.md`, then build after approval. Keep the blueprint brief: files, approach, known constraints, and test plan.

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

---

## sprint start

**Trigger:** "sprint start", "start a sprint for X", "let's work on X" — or any normal/high-risk request to add, fix, update, debug, implement, or build something.

1. **Ticket and context.** Run `sprint start "<title>"`. It creates/starts the
   ticket, records it as active, and ensures `DECISIONS.md` and `HANDOFF.md`
   exist.

2. **Classify tier.** Decide normal vs high-risk using the workflow tiers above.

3. **Planning files.** Create or update the files in `.tickets/<id>/`:
   - `acceptance.md` — specific, binary conditions that define "done"
   - `blueprint.md` — files to inspect, files to create/modify, step-by-step build plan
   - If these already exist: read them and proceed without recreating.
   - Record the tier and one-line reason in `blueprint.md`.

4. **Context.** Read in order:
   - `DECISIONS.md` at repo root — create with empty log table if absent
   - `HANDOFF.md` — create from template if absent, otherwise read current state and discoveries
   - Active sprint files
   - Closed tickets in `.tickets/` that touched files this sprint will modify — note any whose behavior must still hold

5. **Normal path.** For normal-tier work:
   - Inspect the files and callers needed for the requested change.
   - Add `## Approach` and `## Test Plan` to `blueprint.md`.
   - Produce the sprint brief from Step 9.
   - Skip Steps 6-8 unless new findings promote the work to high-risk.

6. **Orient high-risk work.** Run the orient sub-skill: survey the subsystem, trace dependencies, flag non-obvious relationships. Appends `## Subsystem Map` to `blueprint.md`. Findings feed into the Grill step.

7. **Grill high-risk work.** Surface implementation gray areas — decisions that could reasonably go several ways and would materially change what gets built.

   - Analyze the request and identify up to 5 gray areas (API shape, data model, UI behavior, error handling approach, integration pattern, scope boundary, etc.)
   - If no genuine gray areas exist: skip silently.
   - **If gray areas exist:** present them numbered. For each: state the decision to be made and the tradeoffs. Wait for the user to resolve all of them before proceeding.
   - Grill clarifies implementation inside the approved scope; it does not add scope.
   - Log each resolved gray area under `## Grill` in `blueprint.md`.

8. **Impact analysis for high-risk work.** Run the full impact analysis process defined in the impact-analysis skill:
   - Interrogate the request — ask every question whose answer changes the risk profile.
   - Rate all five dimensions (Audience, Reversibility, Blast radius, Trigger paths, Cascade risk).
   - For every HIGH rating: add the required action to `blueprint.md` and the required test to `acceptance.md ## Test Plan`.
   - Past sprint carryover: add regression tests for any closed tickets that touched the same files.
   - Write the `## Impact Assessment` block to `blueprint.md` and `## Test Plan` to `acceptance.md`.
   - If test location is unclear, ask the user before proceeding.

9. **Sprint brief.** Produce:
   - What this sprint accomplishes (one sentence)
   - Tier: trivial skipped / normal / high-risk, with the reason
   - Files expected to be created or modified
   - Impact summary: overall rating + any HIGH dimensions with their required actions called out, or "normal tier — no high-risk triggers found"
   - Acceptance criteria (verbatim from acceptance.md)
   - Test plan (verbatim from acceptance.md ## Test Plan)
   - Any constraints from DECISIONS.md that apply
   - Open questions or blockers still unresolved

10. **Wait for explicit approval.** Do not write code until confirmed. On approval, write `plan.md` to `.tickets/<id>/` with the timestamp, ticket ID, tier, grill resolutions if any, and full approved sprint brief verbatim.

   Re-read `plan.md` after compaction or context reset.

---

## sprint complete

**Trigger:** "sprint complete", "complete the sprint", "ship it"

Verify before closing.

1. **Wrapup.** Run the wrapup pipeline on files modified since sprint start.
   Apply skip rules from `wrapup.md`.

2. **Test verification.** Review each item in `acceptance.md ## Test Plan`:
   - ✓ passed | ✗ failed | ? not run
   - If any ✗ or ?: report which tests did not pass. Do not close the ticket. Stop here.
   - Include impact and regression tests.
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

6. **HANDOFF.md.** Refresh the narrative per the handoff protocol (`../tools/handoff.md`): update `## Current Focus`, `## In Progress`, `## Recent Decisions`, and `## Next Steps` to reflect this sprint. `## Discoveries` is handled by capture mid-build — leave it.

7. **Close.** Run `sprint complete`. If it refuses because checklist items
   remain unchecked, report the blockers and stop.

8. **Report.** One paragraph: what shipped, test results summary, any waived criteria and why, follow-up recorded.

---

## Planning files

Canonical layout:
```
.tickets/<id>/
  ticket.md        ← tkt-managed
  blueprint.md     ← implementation plan; high-risk sprints also include Grill + Impact Assessment
  acceptance.md    ← definition of done + test plan
  plan.md          ← approved sprint brief; written on approval, re-read after compaction
```

## DECISIONS.md

Repo root. Records durable choices future sprints must respect. Not a session log.

```markdown
# Decisions

| Date | Decision | Reason |
|---|---|---|
| 2026-05-17 | Amounts stored as integer cents | Avoid float precision bugs |
```

Write non-obvious choices only. Skip decisions obvious from code.
