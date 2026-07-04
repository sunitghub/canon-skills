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
   | code-simplifier | skipped | docs-only change |
   | code-reviewer | ran | no findings — reviewed the 8-dimension checklist in-context |
   | reviewer | ran | verdict: YES (model: haiku) |
   | security-review | skipped | no security-sensitive patterns |
   | repo-check | skipped | no repo surface changed |
   | doc-audit | ran | README updated |
   | eval | ran | verdict: pass — eval-report.md written (model: haiku) |
   ```

   `code-reviewer` and `reviewer` are two distinct gates, not one — `code-reviewer` is wrapup's own
   in-context 8-dimension check (`skills/wrapup/gates/reviewer.md`, run inline, no verdict, findings
   only); `reviewer` is the fresh-subagent advisory gate below (`skills/sprint/reference/review.md`,
   YES/NO verdict). Both get their own row; do not collapse them into one.

   For the `reviewer` and `eval` rows specifically, always suffix the reason with `(model: <model>)` —
   `haiku` when the model-tier check below matched low-risk, otherwise the session's default model
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
   `skills/**/gates/*.md`, `standards/**/*.md`, or a root-level `*.md` — AND no path name contains a security-sensitive
   marker (`auth`, `secret`, `session`, `crypto`, `token`, `credential`) — a deliberately narrow
   path-name substring list, not the broader semantic "security-sensitive" definitions used
   elsewhere (`SKILL.md`'s high-risk trigger list, `security-review.md`'s skip-logic list).
   Allowlist, not denylist: an unrecognized path type always defaults to normal cost, never to
   cheap — this one rule covers every case the narrow marker list doesn't catch. If low-risk, pass
   `model: "haiku"` on both the reviewer and evaluator `Agent` calls; otherwise omit the `model`
   param on both (today's behavior — inherits the session model). Run the check once; both gates
   use the same low-risk/normal-cost classification (their actual verdicts — YES/NO for reviewer,
   pass/fail for evaluator — remain separate and unrelated to this model-tier check). This is
   file-path pattern matching only — never let the dispatching
   agent's own judgment about the change's riskiness substitute for it or override it downward.
   High-risk-tier sprints are unaffected — the check only ever adds a cheap-model option, it never
   removes the mandatory dispatch itself. **User override:** if the user has explicitly asked to
   keep gates on the full/session model for this sprint, that always wins over an automatic
   low-risk match.

   **Shared gate mechanics (reviewer + evaluator).** Both gates below share four rules, stated
   once here: (a) the close confirmation is authorization to spawn either subagent — never ask for
   separate approval; (b) both subagents derive their own changed-files list via `git merge-base`
   — never pass a file list to either; (c) close each subagent's handle (`TaskStop`) immediately
   after reading its verdict — completed handles still occupy thread slots, and closing the
   reviewer's before step 2 avoids a thread-limit block if the evaluator needs a rerun; (d) each
   subagent must record in its report the model designation it was dispatched with — exactly
   `haiku` if the model-tier check above classified this low-risk, otherwise the exact session
   model id (e.g. `claude-sonnet-5`), never a paraphrase — the same value used in the Wrapup Gates
   table's `(model: <model>)` suffix.

   **Reviewer gate (normal+ tier).** Skip for trivial tier only — meaning `plan.md`'s `## Sign-off`
   line reads `Tier: trivial`. A sprint always starts as normal or high-risk (`SKILL.md`'s tiers
   never let genuinely trivial work start a sprint at all), but a sprint can be *downgraded* to
   trivial mid-flight if grill or impact analysis reveals the real change is a one-liner with no
   coordinated multi-file intent — write `Tier: trivial` and a one-line reason in `## Sign-off` if
   that happens. **This downgrade can never apply to any of `SKILL.md`'s four categorical
   not-trivial triggers** (new file, test/build-infrastructure wiring, hook/pipeline/post-commit
   script change, or coordinated multi-file intent) — those stay normal/high-risk regardless of
   how small the diff looks, so `AGENTS.md`'s "eval is mandatory" for those cases can never be
   bypassed by this escape valve. Absent an explicit, in-bounds downgrade, this gate is mandatory.
   For normal and high-risk sprints, always spawn a freshly invoked Agent subagent for the
   reviewer. Same-context review is not acceptable.

   The reviewer has no implementation history. Invoke with a clean context, per the model-tier
   check above and the shared gate mechanics above. The prompt must instruct it to:
   - Read `skills/sprint/reference/review.md` and follow the review protocol
   - Record its model designation per the shared gate mechanics above
   - Write findings to `.tickets/<id>/review-notes.md` and return the verdict line

   Verdict is `YES` (clean) or `NO` (findings present). The reviewer verdict is **advisory, not blocking** — surface findings to the user, record them in `review-notes.md`, then continue. The evaluator (step 2) owns the binding gate. Record the reviewer outcome in the Wrapup Gates table with the Reason prefixed `verdict:` (e.g. `verdict: YES` or `verdict: NO — <one-line summary>`).

   **Log the subagent run.** Immediately after the reviewer subagent completes, run
   `tools/subagent-log.sh --agent-id <agent-id-from-the-Agent-result> --agent-type reviewer`
   from the project root. This feeds the same `.claude/subagent-runs.jsonl` audit trail the
   evaluator gate (step 2) checks — required now that no `SubagentStop` hook does this
   automatically. Do not skip even though the reviewer itself is advisory; the log entry's
   timestamp is what makes the evaluator's anti-gaming check meaningful.

2. **Evaluator review (normal+ tier).** Same `Tier: trivial` downgrade condition and exclusion as
   the reviewer gate above (skip only if `plan.md`'s `## Sign-off` line reads `Tier: trivial`, which
   can never apply to `SKILL.md`'s four categorical not-trivial triggers). For normal and high-risk
   sprints, always spawn a freshly invoked Agent subagent for the evaluator review, per the shared
   gate mechanics above.

   The evaluator must receive a fresh context with no implementation history and
   grade the work adversarially against `acceptance.md`. Same-context review,
   self-review, or "reviewed directly because delegation needs approval" is not
   an acceptable substitute for normal/high-risk sprints. If the runtime cannot
   spawn the evaluator subagent, stop closeout and report the blocker.

   Invoke a fresh Agent subagent with a clean context, per the model-tier check above. The prompt must instruct it to:
   - Read `skills/sprint/reference/eval.md` and follow the eval protocol
   - Record its model designation per the shared gate mechanics above
   - Write its report to `.tickets/<id>/eval-report.md` and return the verdict line

   **Log the subagent run.** Immediately after the evaluator subagent completes, run
   `tools/subagent-log.sh --agent-id <agent-id-from-the-Agent-result> --agent-type evaluator`
   from the project root, before reading `eval-report.md`. `tools/sprint complete`'s close
   gate (`_gate_eval_report`) hard-fails if `.claude/subagent-runs.jsonl` exists but has no
   entry within ±60 minutes of the `evaluator-run-id` the evaluator wrote — this CLI call is
   what satisfies that check now that no hook does it automatically. Skipping it risks a
   confusing close-time failure on an otherwise-passing sprint.

   Read `.tickets/<id>/eval-report.md` after the subagent completes and close its handle per the
   shared gate mechanics above. Surface any
   `fail` findings to the user before proceeding — this includes any report where individual
   criteria/test-plan items graded `partial`, since `eval.md` requires the verdict line to be
   `fail:` whenever a partial exists (there is no separate non-blocking `partial:` verdict). Do not
   advance to step 3 if the evaluator verdict is `fail`. Record the eval outcome in the Wrapup Gates table with the Reason prefixed `verdict:` (e.g. `verdict: pass` or `verdict: fail — <one-line summary>`).

3. **Test verification.** Review each item in `acceptance.md ## Test Plan`:
   - ✓ passed | ✗ failed | ? not run (maps to `eval.md`'s `pass` / `fail` / `not-run` — same three states, different notation since this step is a human-facing recap, not the evaluator's own report format)
   - If any ✗ or ?: report which tests did not pass. Do not close the ticket. Stop here.
   - Include impact and regression tests.
   - Classify required evidence for each item. Load-bearing test/tool evidence must fail closed when unavailable; preferred evidence may degrade with disclosure; decorative evidence can be dropped. Cached evidence counts only when source, timestamp/version, freshness window, and why that freshness is acceptable are stated.
   - Confirm test results are documented in `acceptance.md` (pass/fail per item, date run, and the evidence checked).
   - Proceed only when all tests are ✓ or explicitly waived by the user with a documented reason.

4. **Acceptance check.** Review each item in `acceptance.md`, including `## QA`'s "Tested
   locally" checkbox — the evaluator does not grade QA (see `eval.md`'s Gotchas); this step is
   where a human confirms it reflects real verification, not just a checked box:
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

9. **Commit & Push.** Always run this at the end, once close succeeds — even if no code changed
   (docs and config still need committing). This step owns Commit & Push — wrapup's own pipeline
   (step 1) never commits, because `DECISIONS.md`/`HANDOFF.md`/`summary.md` are written by steps
   5-7, after wrapup finishes; committing any earlier would miss them.
   - List all modified and untracked files (`git status`). Stage only the files relevant to this
     session's work — never `git add -A`.
   - Draft a commit message per `standards/efficiency.md`'s Git conventions: imperative mood,
     type prefix, 50-char target / 72-char hard limit, no trailing period. Every sprint-backed
     commit includes `Closes: t-xxxx` in the body — this step always has the ticket ID in hand.
     Add more body for breaking changes or non-obvious reasoning.
   - Show the staged files and commit message. Ask: **"Commit and push? (y to proceed)"**
   - On yes: commit, then push to the current branch's remote. Report the pushed ref.
   - If criticals from the review pipeline are unresolved: warn before asking — do not block, but
     make the risk explicit.
