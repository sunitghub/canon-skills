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
   | code-reviewer | ran | no findings — reviewed the 8-dimension checklist in-context |
   | reviewer | ran | verdict: YES (model: haiku) |
   | security | skipped | no security-sensitive patterns |
   | repo-check | skipped | no repo surface changed |
   | doc-audit | ran | README updated |
   | eval | ran | verdict: pass — eval-report.md written (model: haiku) |
   ```

   `code-reviewer` and `reviewer` are two distinct gates, not one — `code-reviewer` is wrapup's own
   in-context 8-dimension check (`skills/wrapup/gates/reviewer.md`, run inline, no verdict, findings
   only); `reviewer` is the fresh-subagent advisory gate below (`skills/sprint/reference/review.md`,
   YES/NO verdict). Both get their own row; do not collapse them into one.

   For the `reviewer` and `eval` rows specifically, always suffix the reason with `(model: <model>)` —
   `haiku` when the model-tier check above matched low-risk, otherwise the session's default model
   name. This is the record of which tier actually ran, not just that the gate ran.

   Use `ran` or `skipped`. Always include a reason — even for gates that ran,
   note what evidence they checked. Avoid bare "ran"; use phrases like
   `reviewed tools/sprint:179-191 and tests/sprint.sh:56-69` or
   `npm test passed 2026-06-13`. This makes the acceptance record complete:
   what was tested and what quality gates ran. **`sprint complete` will block without this section.**

   **Model tier for gates.** This is the documented exception to `AGENTS.md`'s `## Model Tiers`
   `review → Opus` default, scoped only to the two close-gate dispatches below. Before dispatching
   the reviewer or evaluator, compute changed files via
   `git diff --name-only $(git merge-base HEAD origin/main) HEAD` (the same command the reviewer
   prompt uses). If that command returns an empty list (e.g. `origin/main` missing, detached HEAD),
   treat it as normal cost, never low-risk — an empty list is not evidence of low risk, it means the
   check couldn't run. Otherwise, classify low-risk only if every changed path matches an
   allowlist — `docs/**/*.md`, `skills/**/SKILL.md`, `skills/**/reference/**/*.md`,
   `standards/**/*.md`, or a root-level `*.md` — AND no path name contains a security-sensitive
   marker (`auth`, `secret`, `session`, `crypto`, `token`, `credential`). Allowlist, not denylist:
   an unrecognized path type defaults to normal cost, never to cheap. If low-risk, pass
   `model: "haiku"` on both the reviewer and evaluator `Agent` calls; otherwise omit the `model`
   param on both (today's behavior — inherits the session model). Run the check once; both gates
   use the same verdict. This is file-path pattern matching only — never let the dispatching
   agent's own judgment about the change's riskiness substitute for it or override it downward.
   High-risk-tier sprints are unaffected — the check only ever adds a cheap-model option, it never
   removes the mandatory dispatch itself. **User override:** if the user has explicitly asked to
   keep gates on the full/session model for this sprint, that always wins over an automatic
   low-risk match.

   **Reviewer gate (normal+ tier).** Skip for trivial tier only — meaning `plan.md`'s `## Sign-off`
   line reads `tier: trivial`. A sprint always starts as normal or high-risk (`SKILL.md`'s tiers
   never let genuinely trivial work start a sprint at all), but a sprint can be *downgraded* to
   trivial mid-flight if grill or impact analysis reveals the real change is a one-liner with no
   coordinated multi-file intent — write `tier: trivial` and a one-line reason in `## Sign-off` if
   that happens. Absent that explicit downgrade, this gate is mandatory. For normal and high-risk sprints,
   always spawn a freshly invoked Agent subagent for the reviewer. The close confirmation is
   authorization — do not ask for separate approval. Same-context review is not acceptable.

   The reviewer has no implementation history. Invoke with a clean context, per the model-tier
   check above. The prompt must instruct it to:
   - Read `skills/sprint/reference/review.md` and follow the review protocol
   - Ticket ID only — the reviewer derives its own changed-files list via `git merge-base`, same as the evaluator; do not pass a file list
   - Write findings to `.tickets/<id>/review-notes.md` and return the verdict line

   Verdict is `YES` (clean) or `NO` (findings present). The reviewer verdict is **advisory, not blocking** — surface findings to the user, record them in `review-notes.md`, then continue. The evaluator (step 2) owns the binding gate. Record the reviewer outcome in the Wrapup Gates table with the Reason prefixed `verdict:` (e.g. `verdict: YES` or `verdict: NO — <one-line summary>`).

   **Log the subagent run.** Immediately after the reviewer subagent completes, run
   `tools/subagent-log.sh --agent-id <agent-id-from-the-Agent-result> --agent-type reviewer`
   from the project root. This feeds the same `.claude/subagent-runs.jsonl` audit trail the
   evaluator gate (step 2) checks — required now that no `SubagentStop` hook does this
   automatically. Do not skip even though the reviewer itself is advisory; the log entry's
   timestamp is what makes the evaluator's anti-gaming check meaningful.

   **Close the reviewer subagent handle after reading its verdict.** Completed subagents still occupy thread slots — closing before step 2 prevents thread-limit blocks if the evaluator needs a rerun.

2. **Evaluator review (normal+ tier).** Skip for trivial tier only, same `tier: trivial` downgrade
   condition as the reviewer gate above. For normal
   and high-risk sprints, always spawn a freshly invoked Agent subagent for the
   evaluator review. Once the user has confirmed sprint close, do not ask for
   separate approval to spawn the evaluator subagent — the close confirmation is
   authorization for this mandatory gate.

   The evaluator must receive a fresh context with no implementation history and
   grade the work adversarially against `acceptance.md`. Same-context review,
   self-review, or "reviewed directly because delegation needs approval" is not
   an acceptable substitute for normal/high-risk sprints. If the runtime cannot
   spawn the evaluator subagent, stop closeout and report the blocker.

   Invoke a fresh Agent subagent with a clean context, per the model-tier check above. The prompt must instruct it to:
   - Read `skills/sprint/reference/eval.md` and follow the eval protocol
   - Ticket ID only — the evaluator derives its own changed-files list via `git merge-base`; do not pass a file list
   - Write its report to `.tickets/<id>/eval-report.md` and return the verdict line

   **Log the subagent run.** Immediately after the evaluator subagent completes, run
   `tools/subagent-log.sh --agent-id <agent-id-from-the-Agent-result> --agent-type evaluator`
   from the project root, before reading `eval-report.md`. `tools/sprint complete`'s close
   gate (`_gate_eval_report`) hard-fails if `.claude/subagent-runs.jsonl` exists but has no
   entry within ±60 minutes of the `evaluator-run-id` the evaluator wrote — this CLI call is
   what satisfies that check now that no hook does it automatically. Skipping it risks a
   confusing close-time failure on an otherwise-passing sprint.

   Read `.tickets/<id>/eval-report.md` after the subagent completes. **Close the evaluator subagent handle immediately after reading.** Completed handles still occupy thread slots — closing before any rerun prevents thread-limit blocks. Surface any
   `fail` findings to the user before proceeding — this includes any report where individual
   criteria/test-plan items graded `partial`, since `eval.md` requires the verdict line to be
   `fail:` whenever a partial exists (there is no separate non-blocking `partial:` verdict). Do not
   advance to step 3 if the evaluator verdict is `fail`. Record the eval outcome in the Wrapup Gates table with the Reason prefixed `verdict:` (e.g. `verdict: pass` or `verdict: fail — <one-line summary>`).

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

   <one paragraph: what shipped, test results, any waived/deferred items and why, follow-up recorded. For normal+ tier, name which model the reviewer/evaluator gates ran on (pulled from the Wrapup Gates table's `(model: <model>)` suffix) — e.g. "reviewer and evaluator ran on haiku (low-risk classification).">
   ```

   One row per acceptance criterion from `acceptance.md`. Deviations must appear
   in the table — do not bury them in prose. The file appears as a **Summary** tab
   on the ticket board alongside Acceptance and Plan. If a criterion contains a `|`,
   write it as `\|` — bare pipes break the board's table renderer.

8. **Close.** Run `sprint complete` — never write `ticket.md` status directly. If it refuses because a required file is
   missing or checklist items remain unchecked, report the blockers and stop.
