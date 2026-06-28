# Sprint Complete

**Trigger:** "sprint complete", "complete the sprint", "ship it"

**Confirmation required.** Before doing anything, ask:

> "Ready to close sprint `<id>`? This will run wrapup and move the ticket to Done. Confirm to proceed."

Wait for explicit confirmation. Do not proceed if the trigger came from a broad instruction like "resume", "continue", or "finish" without the user specifically approving closeout. The cost of an unwanted close is high; the cost of asking is zero.

1. **Wrapup.** Read `skills/wrapup/SKILL.md`, then run the wrapup pipeline on files modified since sprint start.
   After assessing each gate, append a
   `## Wrapup Gates` section to `acceptance.md` recording every gate's outcome:

   ```markdown
   ## Wrapup Gates
   | Gate | Status | Reason |
   |------|--------|--------|
   | simplifier | skipped | docs-only change |
   | reviewer | ran | verdict: YES |
   | security | skipped | no security-sensitive patterns |
   | repo-check | skipped | no repo surface changed |
   | doc-audit | ran | README updated |
   | eval | ran | verdict: pass — eval-report.md written |
   ```

   Use `ran` or `skipped`. Always include a reason — even for gates that ran,
   note what evidence they checked. Avoid bare "ran"; use phrases like
   `reviewed tools/sprint:179-191 and tests/sprint.sh:56-69` or
   `npm test passed 2026-06-13`. This makes the acceptance record complete:
   what was tested and what quality gates ran. **`sprint complete` will block without this section.**

   **Reviewer gate (normal+ tier).** Skip for trivial tier only. For normal and high-risk sprints,
   always spawn a freshly invoked Agent subagent for the reviewer. The close confirmation is
   authorization — do not ask for separate approval. Same-context review is not acceptable.

   The reviewer has no implementation history. Invoke with a clean context. The prompt must instruct it to:
   - Read `skills/sprint/reference/review.md` and follow the review protocol
   - Ticket ID and changed files: `git diff --name-only $(git merge-base HEAD origin/main) HEAD`
   - Write findings to `.tickets/<id>/review-notes.md` and return the verdict line

   Verdict is `YES` (clean) or `NO` (findings present). The reviewer verdict is **advisory, not blocking** — surface findings to the user, record them in `review-notes.md`, then continue. The evaluator (step 2) owns the binding gate. Record the reviewer outcome in the Wrapup Gates table with the Reason prefixed `verdict:` (e.g. `verdict: YES` or `verdict: NO — <one-line summary>`).

   **Close the reviewer subagent handle after reading its verdict.** Completed subagents still occupy thread slots — closing before step 2 prevents thread-limit blocks if the evaluator needs a rerun.

2. **Evaluator review (normal+ tier).** Skip for trivial tier only. For normal
   and high-risk sprints, always spawn a freshly invoked Agent subagent for the
   evaluator review. Once the user has confirmed sprint close, do not ask for
   separate approval to spawn the evaluator subagent — the close confirmation is
   authorization for this mandatory gate.

   The evaluator must receive a fresh context with no implementation history and
   grade the work adversarially against `acceptance.md`. Same-context review,
   self-review, or "reviewed directly because delegation needs approval" is not
   an acceptable substitute for normal/high-risk sprints. If the runtime cannot
   spawn the evaluator subagent, stop closeout and report the blocker.

   Invoke a fresh Agent subagent with a clean context. The prompt must instruct it to:
   - Read `skills/sprint/reference/eval.md` and follow the eval protocol
   - Ticket ID and changed files: `git diff --name-only $(git merge-base HEAD origin/main) HEAD`
     (captures the full sprint range across multiple commits; assumes `origin/main` as base)
   - Read `acceptance.md`, `plan.md`, and each changed file fresh
   - Write its report to `.tickets/<id>/eval-report.md` and return the verdict line

   Read `.tickets/<id>/eval-report.md` after the subagent completes. **Close the evaluator subagent handle immediately after reading.** Completed handles still occupy thread slots — closing before any rerun prevents thread-limit blocks. Surface any
   `fail` or `partial` findings to the user before proceeding. Do not advance to
   step 3 if the evaluator verdict is `fail`. Record the eval outcome in the Wrapup Gates table with the Reason prefixed `verdict:` (e.g. `verdict: pass` or `verdict: fail — <one-line summary>`).

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
   on the ticket board alongside Acceptance and Plan. If a criterion contains a `|`,
   write it as `\|` — bare pipes break the board's table renderer.

8. **Close.** Run `sprint complete` — never write `ticket.md` status directly. If it refuses because a required file is
   missing or checklist items remain unchecked, report the blockers and stop.
