---
name: sprint
description: Start, plan, and ship a focused change — invoke when asked to add, fix, update, implement, debug, or build anything
category: dev
tags: [workflow, planning, quality, tickets, orchestration]
depends: [capture, ticket, handoff, ticket-layout]
---

@../capture/SKILL.md
@../../standards/ticket-layout.md
@../../tools/handoff.md
@../../tools/ticket.md

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

**Trigger:** "sprint start", "start a sprint for X", "let's work on X" — or any normal/high-risk request to add, fix, update, debug, implement, or build something.

1. **Ticket and context.** Run `sprint start "<title>"`. It creates/starts the
   ticket, records it as active, and ensures `DECISIONS.md` and `HANDOFF.md`
   exist.

2. **Classify tier.** Decide normal vs high-risk using the workflow tiers above.

3. **Planning files.** Create or update the files in `.tickets/<id>/`:
   - `acceptance.md` — specific, binary conditions that define "done"
   - `plan.md` — files to inspect, files to create/modify, step-by-step build plan
   - `research.md` — high-risk and brownfield sprints only; objective compression of truth (see Research below)
   - If these already exist: read them and proceed without recreating.
   - See `ticket-layout` skill for the canonical field contract, doc lifecycle, and board rendering rules.
   - Record the tier and one-line reason in `plan.md`.

4. **Context.** Read in order:
   - `DECISIONS.md` at repo root — create with empty log table if absent. After reading,
     actively scan every entry: identify any that constrain or conflict with this sprint's
     request. A conflict is not a passive note — it must be surfaced in the brief and
     resolved by the user before any implementation proceeds.
   - `HANDOFF.md` — create from template if absent, otherwise read current state and discoveries
   - Active sprint files
   - Closed tickets in `.tickets/` that touched files this sprint will modify — note any whose behavior must still hold

5. **Normal path.** For normal-tier work:
   - Inspect the files and callers needed for the requested change.
   - Add `## Approach` and `## Test Plan` to `plan.md`.
   - Produce the sprint brief from Step 9.
   - Skip Steps 6-8 unless new findings promote the work to high-risk.

6. **Research high-risk work.** Read `skills/internal/orient.md`, then run the orient protocol: survey the subsystem, trace dependencies, flag non-obvious relationships. Writes findings to `.tickets/<id>/research.md` (Objective, Relevant Files, System Model, Constraints, Unknowns, Not In Scope). Findings feed into the Grill step.

   After research is complete, pause and present a brief summary: what was found, key constraints, and open unknowns. Ask the user to review before proceeding to Plan. This is the highest-leverage review checkpoint — a bad research premise produces a bad plan.

   `research.md` is optional for normal-tier work. For lightweight brownfield changes, add a `## Research Notes` section to `plan.md` instead.

7. **Grill high-risk work.** Surface implementation gray areas — decisions that could reasonably go several ways and would materially change what gets built.

   - Analyze the request and identify up to 5 gray areas (API shape, data model, UI behavior, error handling approach, integration pattern, scope boundary, etc.)
   - If no genuine gray areas exist: skip silently.
   - **If gray areas exist:** present them numbered. For each: state the decision to be made and the tradeoffs. Wait for the user to resolve all of them before proceeding.
   - Grill clarifies implementation inside the approved scope; it does not add scope.
   - Log each resolved gray area under `## Grill` in `plan.md`.

   **Pre-mortem.** Once the approach is chosen (gray areas resolved or none found),
   run a pre-mortem on the chosen path:

   > "List what would have to be true for this approach to go badly, ranked by likelihood."

   This is not a re-evaluation of the choice — it's failure-path construction on
   the approved direction. Present findings concisely. If any finding would
   materially change the approach, surface it to the user before proceeding.
   Log the pre-mortem under `## Pre-mortem` in `plan.md`.

8. **Impact analysis for high-risk work.** Read `skills/internal/impact-analysis.md`, then run the full impact analysis process:
   - Interrogate the request — ask every question whose answer changes the risk profile.
   - Rate all five dimensions (Audience, Reversibility, Blast radius, Trigger paths, Cascade risk).
   - For every HIGH rating: add the required action to `plan.md` and the required test to `acceptance.md ## Test Plan`.
   - If the impact-analysis human checkpoint triggers, resolve it before implementation, record the outcome in `plan.md`, and add the required approval checkbox to `acceptance.md ## Test Plan` when HIGH-impact approval is required.
   - Past sprint carryover: add regression tests for any closed tickets that touched the same files.
   - Write the `## Impact Assessment` block to `plan.md` and `## Test Plan` to `acceptance.md`.
   - If test location is unclear, ask the user before proceeding.

9. **Sprint brief.** Produce:
   - What this sprint accomplishes (one sentence)
   - Tier: trivial skipped / normal / high-risk, with the reason
   - **DECISIONS.md conflicts or constraints:** list every applicable entry verbatim. If
     any entry conflicts with the requested approach, call it out explicitly here — do not
     proceed past this point without the user acknowledging the conflict and deciding how
     to resolve it. If none apply, state "no applicable decisions found."
   - Files expected to be created or modified
   - Impact summary: overall rating + any HIGH dimensions with their required actions called out, or "normal tier — no high-risk triggers found"
   - Human checkpoint: required/not required; if required, the decision and approved autonomy
   - Acceptance criteria (verbatim from acceptance.md)
   - Test plan (verbatim from acceptance.md ## Test Plan)
   - Open questions or blockers still unresolved

10. **Wait for explicit approval.** Do not write code until confirmed. On approval, write `plan.md` to `.tickets/<id>/` with the timestamp, ticket ID, tier, grill resolutions if any, and full approved sprint brief verbatim.

   Re-read `plan.md` after compaction or context reset.

   **During implementation, `plan.md` and `acceptance.md` are the source of truth.** If chat history or new discoveries conflict with the approved plan, stop and surface the conflict before changing scope. The agent resolves ambiguity inside the approved scope; scope changes require user confirmation.

## sprint complete

**Trigger:** "sprint complete", "complete the sprint", "ship it"

**Confirmation required.** Before doing anything, ask:

> "Ready to close sprint `<id>`? This will run wrapup and move the ticket to Done. Confirm to proceed."

Wait for explicit confirmation. Do not proceed if the trigger came from a broad instruction like "resume", "continue", or "finish" without the user specifically approving closeout. The cost of an unwanted close is high; the cost of asking is zero.

1. **Wrapup.** Read `skills/wrapup/SKILL.md` and the sub-skill files listed in its `@` imports, then run the wrapup pipeline on files modified since sprint start.
   After assessing each gate, append a
   `## Wrapup Gates` section to `acceptance.md` recording every gate's outcome:

   ```markdown
   ## Wrapup Gates
   | Gate | Status | Reason |
   |------|--------|--------|
   | simplifier | skipped | docs-only change |
   | reviewer | ran | — |
   | security | skipped | no security-sensitive patterns |
   | repo-check | skipped | no repo surface changed |
   | doc-audit | ran | README updated |
   | eval | ran | pass — eval-report.md written |
   ```

   Use `ran` or `skipped`. Always include a reason — even for gates that ran,
   note what evidence they checked. Avoid bare "ran"; use phrases like
   `reviewed tools/sprint:179-191 and tests/sprint.sh:56-69` or
   `npm test passed 2026-06-13`. This makes the acceptance record complete:
   what was tested and what quality gates ran. **`sprint complete` will block without this section.**

2. **Evaluator review (normal+ tier).** Skip for trivial tier. For normal and
   high-risk sprints, invoke the evaluator via the Agent tool with a clean
   context — the evaluator has no implementation history and grades the work
   adversarially against `acceptance.md`.

   Invoke an Agent subagent with a clean context. The prompt must instruct it to:
   - Read `skills/internal/eval.md` and follow the eval protocol
   - Ticket ID and changed files: `git diff --name-only $(git merge-base HEAD origin/main) HEAD`
     (captures the full sprint range across multiple commits; assumes `origin/main` as base)
   - Read `acceptance.md`, `plan.md`, and each changed file fresh
   - Write its report to `.tickets/<id>/eval-report.md` and return the verdict line

   Read `.tickets/<id>/eval-report.md` after the subagent completes. Surface any
   `fail` or `partial` findings to the user before proceeding. Do not advance to
   step 3 if the evaluator verdict is `fail`.

3. **Test verification.** Review each item in `acceptance.md ## Test Plan`:
   - ✓ passed | ✗ failed | ? not run
   - If any ✗ or ?: report which tests did not pass. Do not close the ticket. Stop here.
   - Include impact and regression tests.
   - Classify required evidence for each item. Load-bearing test/tool evidence must fail closed when unavailable; preferred evidence may degrade with disclosure; decorative evidence can be dropped. Cached evidence counts only when source, timestamp/version, freshness window, and why that freshness is acceptable are stated.
   - Confirm test results are documented in `acceptance.md` (pass/fail per item, date run, and the evidence checked).
   - Proceed only when all tests are ✓ or explicitly waived by the user with a documented reason.

4. **Acceptance check.** Review each item in `acceptance.md`:
   - ✓ met | ✗ not met | ? uncertain
   - If any ✗: report what is missing. Do not close the ticket. Stop here.
   - Do not mark an item met from weak evidence: empty or stale output, no stated search scope, vague prose, uninspected generated output, or citations that do not point to changed or directly relevant files.
   - Proceed only when all criteria are ✓ or explicitly waived by the user.

5. **DECISIONS.md.** Append any durable decisions made during this sprint — non-obvious
   architectural choices, explicit tradeoffs, out-of-scope calls. One row per decision.
   Write the WHY, not the what. Skip if no new decisions were made.

6. **Conventions.** While context is fresh, check if any convention-level learnings emerged — patterns, naming norms, non-obvious file relationships, gotchas — that would help a future agent working in this area. These are distinct from decisions: a decision is "we chose X"; a convention is "in this codebase, X always lives next to Y" or "never touch Z without also updating W."
   - If yes: propose the addition (one or two lines) and the target file (`AGENTS.md`, `CLAUDE.md`, or a subdirectory `CLAUDE.md` if one exists). Ask the user to confirm before writing.
   - If no new conventions emerged: skip silently.

7. **Summary.** Write `.tickets/<id>/summary.md` with the plan-vs-actual table and
   a one-paragraph summary. Also output both in chat.

   File format:
   ```markdown
   # Summary

   | Acceptance item | Status | Notes |
   |---|---|---|
   | <criterion verbatim> | delivered / waived / deferred / partial | reason if not delivered |

   <one paragraph: what shipped, test results, any waived/deferred items and why, follow-up recorded>
   ```

   One row per acceptance criterion from `acceptance.md`. Deviations must appear
   in the table — do not bury them in prose. The file appears as a **Summary** tab
   on the ticket board alongside Acceptance and Plan.

8. **Close.** Run `sprint complete`. If it refuses because a required file is
   missing or checklist items remain unchecked, report the blockers and stop.

## Planning files

Canonical layout:
```
.tickets/<id>/
  ticket.md        ← tkt-managed
  acceptance.md    ← definition of done + test plan
  plan.md          ← approach, decisions, grill/impact sections for high-risk; written on approval, re-read after compaction
  research.md      ← optional; high-risk and brownfield sprints only; objective truth compression
  summary.md       ← plan-vs-actual table; written at sprint complete
```

## DECISIONS.md

Repo root. Records durable choices future sprints must respect. Not a session log. Write non-obvious choices only. Skip decisions obvious from code.
