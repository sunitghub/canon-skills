# Sprint Start

**Trigger:** "sprint start", "start a sprint for X", "let's work on X" — or any normal/high-risk request to add, fix, update, debug, implement, or build something.

1. **Ticket and context.** Read `tools/ticket.md`, then run `sprint start "<title>"`. It creates/starts the
   ticket, records it as active, and ensures `DECISIONS.md` and `HANDOFF.md`
   exist.

2. **Skill check.** Run `skills list` (or `skills.sh cmd_list`) and ask: does an existing skill already cover this work? If yes, use it — don't reinvent. If no skill covers it and the work is reusable across projects, note it as a candidate for a new skill in `plan.md`. Building a new skill follows the same sprint flow as any other work.

3. **Classify tier.** Decide normal vs high-risk using the workflow tiers in `skills/sprint/SKILL.md`.

4. **Planning files.** Create or update the files in `.tickets/<id>/` **now** — these are planning artifacts required before the brief. The approval gate in step 11 blocks code, not planning file creation.
   - `acceptance.md` — specific, binary conditions that define "done". For criteria that depend on a server field, computed value, or internal state: name the exact field or condition, not just the user-visible behavior. "Blocked when `acceptance_unchecked` is true" is verifiable; "blocked when items are unchecked" is ambiguous — two similar-sounding conditions can map to different fields and the evaluator cannot distinguish them without live execution.
   - `plan.md` — files to inspect, files to create/modify, step-by-step build plan. For `type: bug` tickets, use `starters/bug-plan.md` as the skeleton — it structures the plan around the five incident stages (Detect/Diagnose/Contain/Fix/Prevent).
   - `research.md` — high-risk and brownfield sprints only; objective compression of truth (see Research below)
   - If these already exist: read them and proceed without recreating.
   - Read `standards/ticket-layout.md` for the canonical field contract, doc lifecycle, and board rendering rules.
   - Record the tier and one-line reason in `plan.md`.

5. **Context.** Read in order:
   - For `type: bug` tickets: grep the repo's bug-pattern log, if present, for similar symptoms before diagnosing. Known patterns reduce time-to-root-cause and avoid repeating past fixes.
   - `DECISIONS.md` at repo root — create with empty log table if absent. After reading,
     actively scan every entry: identify any that constrain or conflict with this sprint's
     request. A conflict is not a passive note — it must be surfaced in the brief and
     resolved by the user before any implementation proceeds.
   - Read `tools/handoff.md`, then: `HANDOFF.md` — create from template if absent, otherwise read current state and discoveries
   - Active sprint files
   - Closed tickets in `.tickets/` that touched files this sprint will modify — note any whose behavior must still hold

6. **Normal path.** For normal-tier work:
   - Inspect the files and callers needed for the requested change.
   - Add `## Approach` and `## Test Plan` to `plan.md`.
   - **Perspective check.** Before drafting the brief, ask one challenge question from each lens: (a) *user* — will the behavior change match what they expect? (b) *security* — does this touch auth, input validation, or trust boundaries? (c) *architect* — does this add surface that canon's minimalism principle would resist? Surface any concern in the brief.
   - Produce the sprint brief from Step 10.
   - Skip Steps 7-9 unless new findings promote the work to high-risk.

7. **Research high-risk work.** Read `skills/sprint/reference/orient.md` and follow the orient protocol. Writes findings to `.tickets/<id>/research.md`. After research is complete, pause and present a brief summary — what was found, key constraints, open unknowns — and ask the user to review before proceeding to Plan. (`research.md` is optional for normal-tier; use a `## Research Notes` section in `plan.md` instead.)

8. **Grill high-risk work.** Surface implementation gray areas — decisions that could reasonably go several ways and would materially change what gets built.

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

9. **Impact analysis for high-risk work.** Read `skills/sprint/reference/impact-analysis.md` and run the full impact analysis process. Writes `## Impact Assessment` to `plan.md` and required mitigation tests to `acceptance.md ## Test Plan`. Resolve any human checkpoint before implementation.

10. **Sprint brief.** Produce:
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

11. **Wait for explicit approval.** Do not write code until confirmed. On approval, update `plan.md` — fill in the risk summary line in `## Sign-off` (`Tier: <tier> | Risk: <blast radius / key risks, one line>` — use tier classification for normal, impact analysis findings for high-risk), check the `- [ ] Plan approved` box, and add any grill resolutions. This is the durable approval record; `sprint complete` gates on it. (`plan.md` was created in step 4 — this step finalizes it, it does not create it.)

    Re-read `plan.md` after compaction or context reset.

    **During implementation, `plan.md` and `acceptance.md` are the source of truth.** If chat history or new discoveries conflict with the approved plan, stop and surface the conflict before changing scope. The agent resolves ambiguity inside the approved scope; scope changes require user confirmation.
