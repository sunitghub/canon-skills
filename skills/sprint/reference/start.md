# Sprint Start

**Trigger:** "sprint start", "start a sprint for X", "let's work on X" — or any normal/high-risk request to add, fix, update, debug, implement, or build something.

1. **Ticket and context.** Read `tools/ticket.md` — inside the canon repo itself this is a plain relative path; inside a consumer project (skills installed via `skills.sh add`) `tools/` isn't symlinked in, so find it via `command -v sprint`'s containing directory instead (or `where sprint` on Windows if `command -v` returns nothing), since `ticket.md` is a sibling of `sprint` there. Then run `sprint start "<title>"` or `sprint start <ticket-id>` — if the user's request already names an existing ticket (e.g. a manually-created ticket, or one referenced by ID), pass that ID verbatim; only pass a title string when no ticket exists yet. This matches `sprint`'s own documented behavior (`sprint start --help`: `sprint start "title"` creates a new ticket, `sprint start <ticket-id>` starts the sprint on an existing ticket with no new ticket created) — it resolves its argument against existing tickets first and only creates a new one if it doesn't match, so passing a paraphrased title instead of the real ID causes a false miss and creates a duplicate ticket. It creates/starts the
   ticket, records it as active, ensures `DECISIONS.md` and `HANDOFF.md` exist, and seeds
   `acceptance.md`/`plan.md` skeletons (see Planning Files below) if they don't already exist.

2. **Skill check.** Run `./tools/skills.sh list` and ask: does an existing skill already cover this work? If yes, use it — don't reinvent. If no skill covers it and the work is reusable across projects, note it as a candidate for a new skill in `plan.md`. Building a new skill follows the same sprint flow as any other work.

3. **Classify tier.** Decide normal vs high-risk using the workflow tiers in `skills/sprint/SKILL.md`.

4. **Planning files.** Both files were already seeded by step 1 (skeleton `## Criteria`/`## Test Plan`/`## QA` in `acceptance.md`, skeleton `## Sign-off`/`## Approach`/`## Files`/`## Decisions` in `plan.md`) — fill them in now, before the brief. The approval gate in step 11 blocks code, not planning file content.
   - `acceptance.md` — specific, binary conditions that define "done" under `## Criteria` and `## Test Plan`. For criteria that depend on a server field, computed value, or internal state: name the exact field or condition, not just the user-visible behavior. "Blocked when `acceptance_unchecked` is true" is verifiable; "blocked when items are unchecked" is ambiguous — two similar-sounding conditions can map to different fields and the evaluator cannot distinguish them without live execution. `## QA`'s "Tested locally" box also blocks close if left unchecked — check it once you've actually verified the change, not before.
   - `plan.md` — files to inspect, files to create/modify, step-by-step build plan under `## Approach`. For `type: bug` tickets, structure the plan around the five incident stages (Detect/Diagnose/Contain/Fix/Prevent). Write `## Approach` per `standards/efficiency.md`'s Token Efficiency section from this first draft, not just when trimming the whole doc for its ~500-word budget at close — it's re-read on every compaction/context reset, so lean prose pays off for the rest of the ticket's lifetime.
   - **Mockup/screenshot artifacts.** If a visual reference (pasted image or a given file path) is provided as the direction for this sprint, save it to `.tickets/<id>/mockups/<name>.<ext>` and cite it in `plan.md`/`acceptance.md` via a path relative to the ticket's own folder — `![alt](mockups/<name>.<ext>)` — not the full API path. The board resolves and renders it inline from that relative reference.
   - `research.md` — objective compression of truth, brief for normal-tier, full orient protocol for high-risk/brownfield (see Research below)
   - If these already exist with real content (not just the skeleton): read them and proceed without recreating.
   - Read `standards/ticket-layout.md` for the canonical field contract, doc lifecycle, and board rendering rules.
   - Record the tier and one-line reason in `plan.md`.

5. **Context.** Read in order:
   - For `type: bug` tickets: grep the repo's bug-pattern log, if present, for similar symptoms before diagnosing. Known patterns reduce time-to-root-cause and avoid repeating past fixes.
   - `DECISIONS.md` at repo root — create with empty log table if absent. After reading,
     actively scan every entry: identify any that constrain or conflict with this sprint's
     request. A conflict is not a passive note — it must be surfaced in the brief and
     resolved by the user before any implementation proceeds.
   - Read `tools/handoff.md` (same resolution as step 1's `tools/ticket.md` — plain relative path in canon itself, or via `command -v sprint`'s directory in a consumer project, or `where sprint` on Windows if `command -v` returns nothing), then: `HANDOFF.md` — create from template if absent, otherwise read current state and discoveries
   - Active sprint files
   - Closed tickets in `.tickets/` that touched files this sprint will modify — note any whose behavior must still hold

6. **Normal path.** For normal-tier work:
   - Inspect the files and callers needed for the requested change.
   - Write a brief `research.md` — a few bullets of findings and constraints — before drafting `## Approach`. Keep it short; this is not the full orient protocol (see step 7 for why this file matters even when planning stays in the same session).
   - Fill in `## Approach` in `plan.md` and `## Test Plan` in `acceptance.md` (not `plan.md` — `plan.md`'s skeleton has no Test Plan heading, and every grading step reads/grades it from `acceptance.md`). Both headings already exist from step 1's skeleton — this is filling them in, not creating them.
   - **Perspective check.** Before drafting the brief, ask one challenge question from each lens: (a) *user* — will the behavior change match what they expect? (b) *security* — does this touch auth, input validation, or trust boundaries? (c) *architect* — does this add surface that canon's minimalism principle would resist? Surface any concern in the brief.
   - Produce the sprint brief from Step 10.
   - Skip Steps 7-9 unless new findings promote the work to high-risk.

7. **Research high-risk work.** Read `skills/sprint/reference/orient.md` and follow the orient protocol. Writes findings to `.tickets/<id>/research.md`. After research is complete, pause and present a brief summary — what was found, key constraints, open unknowns — and ask the user to review before proceeding to Plan. (Normal-tier writes the same file, just brief — per step 6 — instead of running the full orient protocol. Either way, a planning step reads curated findings from `research.md`, not the raw exploration transcript.)

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

11. **Wait for explicit approval.** Do not write code until confirmed. On approval, update `plan.md` — fill in the risk summary line in `## Sign-off` (`Tier: <tier> | Risk: <blast radius / key risks, one line>` — use tier classification for normal, impact analysis findings for high-risk), check the `- [ ] Plan approved` box, and add any grill resolutions. This is the durable approval record; `sprint complete` gates on it. (`plan.md` was created in step 4 — this step finalizes it, it does not create it.) If a normal/high-risk sprint turns out mid-flight to be genuinely trivial (grill or impact analysis reveals a one-liner with no coordinated multi-file intent, and the change is not one of `SKILL.md`'s four categorical not-trivial triggers — new file, test/build-infrastructure wiring, hook/pipeline/post-commit script change, or coordinated multi-file intent), the `## Sign-off` line can instead read `Tier: trivial | Risk: <reason>` — see `skills/sprint/reference/complete.md`'s reviewer/evaluator gates for what that downgrade skips.

    Re-read `plan.md` after compaction or context reset.

    **During implementation, `plan.md` and `acceptance.md` are the source of truth.** If chat history or new discoveries conflict with the approved plan, stop and surface the conflict before changing scope. The agent resolves ambiguity inside the approved scope; scope changes require user confirmation.
