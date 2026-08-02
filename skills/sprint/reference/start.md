# Sprint Start

**Trigger:** "sprint start", "start a sprint for X", "let's work on X" — or any normal/high-risk request to add, fix, update, debug, implement, or build something.

## Contents

Steps (normal-tier skips 7-9; high-risk runs the full pipeline):
- 1. Ticket and context
- 2. Skill check
- 3. Classify tier
- 4. Planning files
- 5. Context
- 6. Normal path
- 7. Research high-risk work
- 8. Grill high-risk work
- 9. Impact analysis for high-risk work
- 10. Sprint brief
- 11. Wait for explicit approval

1. **Ticket and context.** Read `tools/ticket.md` — plain relative path inside canon itself; inside a consumer project (`tools/` not symlinked in), find it via `command -v sprint`'s containing directory instead (`where sprint` on Windows if `command -v` returns nothing) — `ticket.md` sits beside `sprint` there. Then run `sprint start "<title>"` or `sprint start <ticket-id>`. If the request already names an existing ticket, pass that ID verbatim — only pass a title when no ticket exists yet. Per `sprint start --help`: a title creates a new ticket; an ID starts the sprint on the existing one, no duplicate created. It matches its argument against existing tickets first, so a paraphrased title instead of the real ID causes a false miss and a duplicate ticket. `sprint start` creates/starts the ticket, marks it active, ensures `DECISIONS.md`/`HANDOFF.md` exist, and seeds `acceptance.md`/`plan.md` skeletons (see Planning Files) if absent. Once started, **read the ticket's own docs before drafting a plan or asking the user for direction**: `.tickets/<id>/ticket.md` (the Description), `acceptance.md`, and `plan.md` — plus `research.md` if present. This `.tickets/<id>/ticket.md` is a **different file** from the CLI helper `tools/ticket.md` named at the start of this step: the helper documents the `tkt`/`sprint` commands; the ticket's own `ticket.md` holds the Description and frontmatter. An empty or template-only Description does not mean the work is unspecified — the build contract may live entirely in `acceptance.md`/`plan.md` (see Planning Files).

2. **Skill check.** Run `./tools/skills.sh list` and ask: does an existing skill already cover this work? If yes, use it — don't reinvent. If no skill covers it and the work is reusable across projects, note it as a candidate for a new skill in `plan.md`. Building a new skill follows the same sprint flow as any other work.

3. **Classify tier.** Decide normal vs high-risk using the workflow tiers in `skills/sprint/SKILL.md`. The `trivial` and `bugfix` tiers are not chosen here — they are *complete-time downgrades* decided at close from the actual diff (see `reference/complete.md` steps 2-3); a sprint always starts as normal or high-risk.
   - **Docs/UX light-close recognition.** If the request reads as docs/research/UX
     work — signals like *study, research, docs, documentation, UX, mockup, screen
     mockup, wireframe, design*, and the deliverable is `.md`/`.pen` (+ exported
     visuals) with no code — *propose* the Demo/Docs/UX light-close (offer to run
     `tkt demo <id> on`) and say why: heavy wrapup + the advisory reviewer add
     little with no code, while the binding Haiku evaluator still grades the
     doc/mockup against `acceptance.md`. It stays user-elected — propose, don't
     auto-apply — and rides on top of the normal/high-risk tier you classified
     above; it is not a substitute for that classification. A request that also
     touches code is a full sprint regardless of keywords. See `SKILL.md`'s
     "Demo / Docs / UX (light close)" section.

4. **Planning files.** Both files were already seeded by step 1 (skeleton `## Criteria`/`## Test Plan`/`## QA` in `acceptance.md`, skeleton `## Sign-off`/`## Approach`/`## Files`/`## Decisions` in `plan.md`) — fill them in now, before the brief. The approval gate in step 11 blocks code, not planning file content.
   - `acceptance.md` — specific, binary conditions that define "done" under `## Criteria` and `## Test Plan`. For criteria that depend on a server field, computed value, or internal state: name the exact field or condition, not just the user-visible behavior. "Blocked when `acceptance_unchecked` is true" is verifiable; "blocked when items are unchecked" is ambiguous — two similar-sounding conditions can map to different fields and the evaluator cannot distinguish them without live execution. `## QA`'s "Tested locally" box also blocks close if left unchecked — check it once you've actually verified the change, not before. This "not before" discipline applies to every box in `## Criteria`, `## Test Plan`, and `## QA`, not just this one: tick each box at the moment its evidence exists, never in bulk. A single find-replace across the checklist converts unverified items into claims silently, and `sprint complete` cannot tell the difference — it gates on boxes being *checked*, not on them being *true*. Live-reproduced (overtone-app `t-f413`): three items were bulk-ticked, including "verified across all 25 nodes", which the evaluator later falsified against a capture containing 15.
   - **Visual acceptance criteria (required for UI-affecting work).** If this
     sprint changes anything user-visible — UI layout, component markup,
     styling/CSS (**including CSS embedded in code**: Streamlit `_CSS` strings,
     styled-components/CSS-in-JS, inline `style=` attributes, theme tokens),
     theming, or a widget swap — `acceptance.md ## Criteria` **must** include at
     least one *visual* criterion pinning the expected **rendered** state of the
     affected element (e.g. "the primary Ask button renders with the aqua→green
     gradient fill and dark label"), and `## Test Plan` must include a
     rendered-output verification step. The trigger is *user-visible impact*, not
     the file extension in the diff — a change that touches no `.css`/`.html`
     file (a `_CSS`-string edit, or a widget swap that changes a rendered testid)
     is still a UI change. **Logic/unit tests are render-blind:** Streamlit
     AppTest, jsdom, and logic-only snapshots verify behavior/DOM structure but
     cannot see computed styles, gradients, or a rendered testid — a criterion
     that only asserts behavior will not catch a styling regression (live case:
     overtone `t-b75f` wrapped a button in `st.form`, silently changing its
     testid and dropping its gradient, invisible to AppTest until a later bug
     ticket). The reviewer/evaluator verify visual criteria against actual
     rendered output — see `shared-gate-protocol.md ## Self-serve visual
     verification` for the browser-binary recipe (no Node/Playwright needed).
   - **Scenario-backed acceptance criteria (optional — for input→output claims).** A criterion
     that is a genuine input→output claim MAY carry a Given/When/Then block — an inline
     ` ```gherkin ` block (`t-6e32`), or a ` ```gherkin-file ` reference to a ticket-local
     `.feature` (`t-f89a`). If it does, `## Test Plan` **must** name the exact runner command
     that executes it (e.g. `python dsl_runner.py specs/discount.feature`): the evaluator grades a
     **scenario-backed** criterion by *running that command and reading the boolean exit code*,
     not by reading prose. A ` ```gherkin-file ` reference MAY additionally carry a
     `runner: <cmd>` line inside the fence (e.g. `runner: python dsl_runner.py`, `t-6f8e`) — when
     present it is the **structured home** of the runner command: the board renders the resolved
     `<runner> <feature-path>` beneath the scenario panel (display only — the board never executes
     it) and the evaluator forms and runs that same command, so the command travels with the spec
     it checks instead of living only in prose. The `## Test Plan` item still carries the checkable
     line (it may restate that command or reference the scenario's runner). canon ships no runner —
     the project provides a small fixed-pattern one
     (see `examples/dsl-discount-spec/dsl_runner.py`), deliberately not a general Gherkin engine.
     This is additive — most criteria stay prose; use it only where a machine can answer
     pass/fail. **Ordering (what makes it a real check):** scenario-backed criteria must be
     **locked at the sprint-start approval gate**, before implementation — never add or edit a
     scenario during implementation to match the code you just wrote. A spec authored alongside
     the code it checks is a regression lock, not a correctness proof; the fresh evaluator
     discloses a scenario that appears authored or edited alongside the implementation.

     **Build instruction (seed into `plan.md`).** When a scenario-backed criterion is present and the
     implementation doesn't exist yet, seed a reusable *build instruction* into `plan.md` so the
     author only had to write the readable scenario: (1) extract the scenario into a derived
     `.feature` — Acceptance stays the source, don't hand-edit the `.feature`; (2) **infer the
     function _signature_ only** from the scenario (`Given` → inputs, `Then` → output fields) — the
     author supplies no signature. Inference stops at the signature: it does **not** extend to
     business-rule *values*; (3) implement it — **default JavaScript** (`app/<name>.js`); (4) build a small
     fixed-pattern runner whose default command is `node dsl_runner.js specs/<name>.feature`; (5) **write the runner command into `## Test Plan` yourself — one line per
     `.feature`** (option B: the agent owns the command because it chose the name/path/language;
     never hardcode it for the author — `t-a2f0`); (6) **never invent rule values the scenarios don't
     pin.** Before implementing, list every behavior the scenarios leave unspecified — exact
     thresholds, rates, boundary/edge values, ranges *between* the given data points, unhandled
     inputs — and surface them to the user as explicit gaps to confirm; a scenario proving "40 is
     rejected" pins only "min > 40", never "min = 50". Ask if the signature **or** any rule value is
     ambiguous — do not fill the gap with a plausible guess (a guessed threshold still makes the
     runner pass, so neither the runner nor the fresh evaluator will catch it — `t-ef19`).
     The board seeds the matching `## Test Plan` *placeholder* in Acceptance on save when a scenario
     is present (`t-321a`, never a hardcoded command); `sprint start` writes this build instruction
     into `plan.md`. Worked block: `examples/dsl-discount-spec/README.md`. **Language default is
     JavaScript** — the `python dsl_runner.py …` examples in the scenario-backed rules above (and in
     `eval.md`/`complete.md`) are language-agnostic illustrations of *a runner command*, not a Python
     mandate; use Python (`discount.py` + `python dsl_runner.py`) only when the user asks for it.
   - `plan.md` — files to inspect, files to create/modify, step-by-step build plan under `## Approach`. For `type: bug` tickets, structure the plan around the five incident stages (Surface/Trace/Isolate/Resolve/Harden). Write `## Approach` per `standards/efficiency.md`'s Token Efficiency section from this first draft, not just when trimming the whole doc for its ~500-word budget at close — it's re-read on every compaction/context reset, so lean prose pays off for the rest of the ticket's lifetime.
   - **Visual reference artifacts.** Visual reference (pasted image, or a file path
     from the user — including an absolute host path like `C:\...\Mockup-1.jpg`) as
     sprint direction:
     1. **Copy the actual file** to `.tickets/<id>/visuals/<name>.<ext>` — name alone
        isn't enough; the board only serves images from inside the ticket's own
        folder, so a file left at its original location is unreachable.
     2. **Insert a real markdown image embed** — `![alt](visuals/<name>.<ext>)`,
        relative to the ticket's own folder, not the full API path — in
        `plan.md`/`acceptance.md`. A bare or backticked filename mention (e.g.
        `` `Mockup-1.jpg` `` or `` `visuals/<name>.<ext>` `` in prose) is not an
        embed and renders as plain text.
     3. **Multiple candidates** (e.g. two UI options): name each distinctly
        (`visuals/option-a.png`, `visuals/option-b.png`), embed all candidates in
        `plan.md` alongside the choice under `## Decisions`, embed only the chosen
        one in `acceptance.md` — keep discarded candidates in `visuals/` for
        traceability, don't delete. Before writing each candidate's label and
        description, `Read` that specific copied file again and describe what's
        actually seen — live-reproduced failure: two visuals got swapped relative
        to their labels, tracked by copy/filename order instead of re-checking the
        file itself, so "Candidate A" described the wrong image. No mechanical gate
        catches this (`_gate_visual_embed` only checks a real embed exists and the
        file is present, not that content matches label) — fix is re-verifying at
        write time.

     `sprint complete`'s `_gate_visual_embed` enforces both steps mechanically — it
     blocks close if any image-extension filename mentioned in `plan.md`/`acceptance.md`
     never resolves to a real embed in that same file, or if a real embed's target file
     was never actually copied to `visuals/`.
   - `research.md` — objective compression of truth, brief for normal-tier, full orient protocol for high-risk/brownfield (see Research below)
   - If these already exist with real content (not just the skeleton): read them and proceed without recreating.
   - **A template-only Description is not "unspecified."** A ticket created on the board carries a seeded Description type-template (`## Description` followed by `What should be built?` / `What should be done?` / `What is broken?` etc.) — that prompt is not a real description. When `acceptance.md` (criteria/scenario) or `plan.md` already specify the work, treat **that** as the build contract and proceed; do not stall or ask the user for direction solely because the Description is empty or still the seeded template.
   - Read `standards/ticket-layout.md` for the canonical field contract, doc lifecycle, and board rendering rules.
   - Record the tier and one-line reason in `plan.md`.
   - **Job-type planning step (JTBD).** Job type is *orthogonal to risk tier* — it adds a
     planning step, it never changes which gates run. Before drafting `## Approach`, route by job:
     - `type: bug` → run **root-why** (read `skills/sprint/reference/root-why.md`): the 5-Whys
       root cause, and convert the reported bug into an independently-stated corrected invariant
       + ≥1 hand-computed worked example before any code. This complements the five-incident-stage
       plan structure noted in the `plan.md` bullet above.
     - **refactor job** (restructuring without behavior change) → run the **mikado** skill to
       produce a reversible dependency graph before touching code; log the graph in `plan.md`.
       (Refactor is recognized as a job shape here, not a ticket `type`.)
     - any other type → no extra planning step.

5. **Context.** Read in order:
   - For `type: bug` tickets: grep the repo's bug-pattern log, if present, for similar symptoms before diagnosing. Known patterns reduce time-to-root-cause and avoid repeating past fixes.
   - `DECISIONS.md` at repo root — create with empty log table if absent. After reading,
     actively scan every entry: identify any that constrain or conflict with this sprint's
     request. A conflict is not a passive note — it must be surfaced in the brief and
     resolved by the user before any implementation proceeds. `DECISIONS-archive.md` (if
     present) holds entries already superseded — historical reference, not part of this scan.
   - Read `tools/handoff.md` (same resolution as step 1's `tools/ticket.md` — plain relative path in canon itself, or via `command -v sprint`'s directory in a consumer project, or `where sprint` on Windows if `command -v` returns nothing), then: `HANDOFF.md` — create from template if absent, otherwise read current state and discoveries
   - Active sprint files
   - Closed tickets in `.tickets/` that touched files this sprint will modify — note any whose behavior must still hold

6. **Normal path.** For normal-tier work:
   - Inspect the files and callers needed for the requested change.
   - Write a brief `research.md` — a few bullets of findings and constraints — before drafting `## Approach`. Keep it short; this is not the full orient protocol (see step 7 for why this file matters even when planning stays in the same session).
   - Fill in `## Approach` in `plan.md` and `## Test Plan` in `acceptance.md` (not `plan.md` — `plan.md`'s skeleton has no Test Plan heading, and every grading step reads/grades it from `acceptance.md`). Both headings already exist from step 1's skeleton — this is filling them in, not creating them.
   - **Perspective check.** Before drafting the brief, ask one challenge question from each lens: (a) *user* — will the behavior change match what they expect? (b) *security* — does this touch auth, input validation, or trust boundaries? (c) *architect* — does this add surface that canon's minimalism principle would resist? Surface any concern in the brief. **This check is not normal-tier-only: high-risk sprints run the same three-lens perspective check during orient (step 7), before presenting the research summary. It is complementary to grill (step 8), not subsumed by it — grill resolves implementation gray areas within the approved scope, while the perspective check challenges the change itself from the user/security/architect lenses.**
   - Produce the sprint brief from Step 10.
   - Skip Steps 7-9 unless new findings promote the work to high-risk.

7. **Research high-risk work.** Read `skills/sprint/reference/orient.md` and follow the orient protocol. Writes findings to `.tickets/<id>/research.md`. Also run step 6's **Perspective check** (the user/security/architect lenses) here, and fold any concern into the summary you present. After research is complete, pause and present a brief summary — what was found, key constraints, open unknowns — and ask the user to review before proceeding to Plan. (Normal-tier writes the same file, just brief — per step 6 — instead of running the full orient protocol. Either way, a planning step reads curated findings from `research.md`, not the raw exploration transcript.)

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

11. **Wait for explicit approval.** Do not write code until confirmed. On approval, update `plan.md` — fill in the risk summary line in `## Sign-off` (`Tier: <tier> | Risk: <blast radius / key risks, one line>` — use tier classification for normal, impact analysis findings for high-risk), check the `- [ ] Plan approved` box, and add any grill resolutions. This is the durable approval record; `sprint complete` gates on it. (`plan.md`'s skeleton was seeded in step 1 and filled in during step 4 — this step finalizes it, it does not create it.) If a normal/high-risk sprint turns out mid-flight to be genuinely trivial (grill or impact analysis reveals a one-liner with no coordinated multi-file intent, and the change is not one of `SKILL.md`'s four categorical not-trivial triggers — new file, test/build-infrastructure wiring, hook/pipeline/post-commit script change, or coordinated multi-file intent), the `## Sign-off` line can instead read `Tier: trivial | Risk: <reason>` — see `skills/sprint/reference/complete.md`'s reviewer/evaluator gates for what that downgrade skips.

    **Optional gate-model override.** If the user asks (now, or any time before `sprint
    complete` runs) to run the close-gate reviewer/evaluator on a specific model — e.g.
    "run review/eval on haiku" — append `| Gate model: <value>` to the same Sign-off line
    (`<value>` is case-insensitive: a model id such as `haiku`/`opus`, or the literal
    `session` to force full session-model review — there is no separate `auto` value;
    omitting the field entirely already means automatic). Write it immediately when asked,
    not deferred, so a later compaction doesn't lose it. A user can also add this segment
    by hand-editing `plan.md` directly, without asking — the skeleton seeded in step 1
    already carries a commented hint showing the exact syntax and valid values. See
    `complete.md`'s "Model tier for gates" for how this value is applied at close.

    Re-read `plan.md` after compaction or context reset.

    **During implementation, `plan.md` and `acceptance.md` are the source of truth.** If chat history or new discoveries conflict with the approved plan, stop and surface the conflict before changing scope. The agent resolves ambiguity inside the approved scope; scope changes require user confirmation.

    **If `acceptance.md ## Criteria` is edited or gains an item mid-sprint, sync `acceptance.md ## Test Plan` in the same pass** — add coverage for the new/changed behavior, and fix any existing Test Plan line whose coverage no longer matches. Do this before reporting the update as done, not only when asked. If the change also affects the implementation approach, update `plan.md ## Approach` too.
