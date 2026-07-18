# Sprint Complete

**Trigger:** "sprint complete", "complete the sprint", "ship it"

**Confirmation required.** Before anything, ask:

> "Ready to close sprint `<id>`? This will run wrapup and move the ticket to Done. Confirm to proceed."

Wait for explicit confirmation. Don't proceed on a broad instruction like "resume"/"continue"/"finish" without specific close approval. An unwanted close is costly; asking is free.

1. **Wrapup.** Read `skills/wrapup/SKILL.md`, run the wrapup pipeline (code-simplifier, code-reviewer, security-review, repo-check, doc-audit, then refresh docs) over the sprint's changed files — scope varies by gate: wrapup's memory-scoped gates (code-simplifier, code-reviewer) only see "code touched this session", so a multi-session sprint won't get earlier-session files re-checked by those two; security-review derives scope from git instead. `reviewer`/`evaluator` (steps 2-3 below, not part of this pipeline) also diff against `origin/main`, so they cover the full sprint regardless of session boundaries.

   The "Wrapup Gates" table also records `reviewer`/`eval` — the two close-time gates outside the wrapup pipeline (steps 2-3). After assessing each gate, append a `## Wrapup Gates` section to `acceptance.md` (row order below is an illustrative record, not the execution order — `reviewer`/`eval` actually run at steps 2-3, after the pipeline gates):

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

   `code-reviewer` and `reviewer` are distinct gates — `code-reviewer` is wrapup's in-context
   8-dimension check (`skills/wrapup/gates/reviewer.md`, inline, findings only, no verdict);
   `reviewer` is the fresh-subagent advisory gate below (`skills/sprint/reference/review.md`,
   YES/NO verdict). Separate rows — never collapse.

   For the `reviewer`/`eval` rows, always suffix the reason with `(model: <model>)` — the
   value actually applied by the model-tier check below: an explicit `Gate model:` value,
   `haiku` if the structural check matched low-risk, or the exact session model id (e.g.
   `claude-sonnet-5`), never a paraphrase. Records which tier actually ran.

   Use `ran`/`skipped`, always with a reason — even for gates that ran, note the evidence
   checked. Avoid bare "ran"; use e.g. `reviewed tools/sprint:179-191 and tests/sprint.sh:56-69`
   or `npm test passed 2026-06-13`. **`sprint complete` blocks without this section.**

   **Model tier for gates.** Documented exception to `AGENTS.md`'s `## Model Tiers` `review →
   Opus` default, scoped only to the two close-gate dispatches below.

   - **Explicit Gate model override wins — check first.** Read `plan.md`'s `## Sign-off` line
     for a `| Gate model: <value>` segment. Valid `<value>`s (case-insensitive): a model id
     (`haiku`, `sonnet`, `opus`), or literal `session` to force full session-model review — no
     separate `auto`; omitting the field already means automatic. Set only by a live user
     instruction ("run review/eval on haiku") or manual edit — never inferred or asserted by
     the dispatching agent itself. If asked verbally and the field isn't in `plan.md` yet, write it
     immediately, before continuing — so a compaction between ask and dispatch doesn't lose
     it. If present, skip structural classification and jump to **Apply the result** with this
     value. If absent, fall through.
   - **Compute changed files.** `git diff --name-only $(git merge-base HEAD origin/main) HEAD`
     (same command the reviewer prompt uses).
   - **Check `git merge-base`'s exit status, not the diff output.** Failure (missing
     `origin/main`, detached HEAD, no git baseline) means normal cost, never low-risk — a
     failed substitution can leave the outer `git diff` running against a different,
     non-empty baseline, so empty output is neither guaranteed nor evidence of low risk. Only
     exit status is reliable.
   - **Classify low-risk** only if every changed path matches the allowlist — `docs/**/*.md`,
     `skills/**/SKILL.md`, `skills/**/reference/**/*.md`, `skills/**/gates/*.md`,
     `standards/**/*.md`, or root-level `*.md` — AND no path contains a security marker
     (`auth`, `secret`, `session`, `crypto`, `token`, `credential`). This substring list is
     deliberately narrower than the semantic "security-sensitive" definitions elsewhere
     (`SKILL.md`'s high-risk triggers, `security-review.md`'s skip list). Allowlist, not
     denylist: any non-matching path defaults to normal cost — never overridden downward by
     the agent's own risk judgment.
   - **Apply the result.** With an explicit `Gate model:` value: `session` → omit `model`
     (inherits session model); any other value → pass it verbatim as `model` on both reviewer
     and evaluator `Agent` calls. Without one: low-risk → pass `model: "haiku"`; otherwise
     omit `model`. Check once; both gates share the result — their verdicts (YES/NO,
     pass/fail) stay separate from this check.
   - **High-risk sprints are unaffected** — the check only adds a cheap-model option, never
     removes the mandatory dispatch. An explicit `Gate model:` override applies regardless of
     tier.
   - **Cross-harness caveat.** The automatic Haiku downgrade is confirmed only under Claude
     Code. Per `AGENTS.md`'s `## Model Tiers` note, Codex's `spawn_agent` has no per-agent
     `model` field (its model picker is session-level), so don't assume the downgrade takes
     effect under Codex without testing live first — an explicit `Gate model:` override or
     full-tier review is the safe default there.

   **Shared gate mechanics (reviewer + evaluator).** Four rules, stated once: (a) close
   confirmation authorizes spawning either subagent — never ask separately; (b) both derive
   their own changed-files list via `git merge-base` — never pass one in; (c) close each
   subagent's handle (`TaskStop`) right after reading its verdict — completed handles still
   occupy thread slots, and closing the reviewer's before step 3 avoids a thread-limit block if
   the evaluator needs a rerun; if `TaskStop` errors with `not running (status: completed)`,
   that's expected (the harness may already auto-free a completed task's slot) — proceed, don't
   retry or treat it as fatal; (d) each subagent records its model designation in its report
   — the exact value applied above (an explicit `Gate model:` value, `haiku` if the
   structural check classified this low-risk, or the exact session model id, e.g.
   `claude-sonnet-5`), never a paraphrase — same value as the Wrapup Gates table's
   `(model: <model>)` suffix; (e) **what to pass for `<id>` in `subagent-log.sh`:** the gate
   matches only on the log entry's timestamp, never on `agent_id` — so a harness-provided
   dispatch id is not required. Use whichever is available: (1) a trailing `agentId: <id>`
   token if the raw Agent-call result exposes one, (2) otherwise a stable synthetic id such as
   `reviewer-<ticket-id>` or the evaluator's own `evaluator-run-id`. Do not stall or switch
   dispatch modes hunting for a token — a `Plan`-type foreground `Agent` call may expose none
   (reproduced in canon `t-9a75` and a separate Windows project `t-6cd0`); (f) **if a
   subagent's Bash file-writing is refused outright** (permission boundary, not heredoc
   failure): do not retry or re-dispatch with a broader-permission `subagent_type`. Check
   whether the expected report file exists after dispatch; if not, save the returned report
   text yourself before continuing.

2. **Reviewer gate (normal+ tier).** Skip only if `plan.md`'s `## Sign-off` section's `Tier:`
   field value itself is `trivial` (anchored to that field, so "trivial" appearing elsewhere in
   Sign-off's free text — e.g. a `Risk:` one-liner discussing the decision — never triggers the
   skip). A sprint always starts as normal or high-risk (`SKILL.md`'s tiers never let genuinely
   trivial work start a sprint), but can be *downgraded* to trivial mid-flight if grill or
   impact analysis reveals the real change is a one-liner with no coordinated multi-file intent
   — write `Tier: trivial` and a one-line reason in `## Sign-off` if that happens. **This
   downgrade can never apply to any of `SKILL.md`'s four categorical not-trivial triggers**
   (new file, test/build-infrastructure wiring, hook/pipeline/post-commit script change, or
   coordinated multi-file intent) — those stay normal/high-risk regardless of how small the
   diff looks, so `AGENTS.md`'s "eval is mandatory" for those cases can never be bypassed by
   this escape valve. Absent an explicit, in-bounds downgrade, this gate is mandatory. For
   normal and high-risk sprints, always spawn a freshly invoked Agent subagent for the
   reviewer. Same-context review is not acceptable.

   Reviewer has no implementation history. Invoke with a clean context, per the model-tier
   check and shared gate mechanics above. **Pass `subagent_type: "Plan"`** on the `Agent`
   call — the only mechanism that actually restricts a dispatched subagent's tools; the `Plan`
   type excludes Edit, Write, and Agent at the harness level (Bash stays available, needed for
   git commands and writing the report via `cat >>`). Chosen over `Explore` (same tool
   restriction) because `Explore`'s own description warns it reads excerpts rather than whole
   files — wrong fit for adversarial full-file review; the dispatch prompt overrides `Plan`'s
   default architect framing regardless. Prompt must instruct it to:
   - Read `skills/sprint/reference/review.md` and follow the review protocol
   - Record its model designation per the shared gate mechanics above
   - Write findings to `.tickets/<id>/review-notes.md` and return the verdict line

   **If the subagent's Bash refused to write the file:** see shared gate mechanics (f) above.
   Check whether `.tickets/<id>/review-notes.md` exists after dispatch; if not, save the
   returned report text yourself.

   Verdict is `YES` (clean) or `NO` (findings present). The reviewer verdict is **advisory, not
   blocking** — surface findings to the user, record them in `review-notes.md`, then continue.
   The evaluator (step 3) owns the binding gate. Record the reviewer outcome in the Wrapup
   Gates table with the Reason prefixed `verdict:` (e.g. `verdict: YES` or `verdict: NO — <one-line summary>`).

   **Log the subagent run.** Immediately after the reviewer subagent completes, run
   `subagent-log.sh --agent-id <id> --agent-type reviewer` (bare — it's on PATH, same as
   `sprint`/`tkt`). This writes to the same `.claude/subagent-runs.jsonl` audit trail as the
   evaluator's own log call (step 3) — required now that no `SubagentStop` hook does this
   automatically. `_gate_eval_report` (step 3) matches by timestamp only, not `agent_type` or
   `agent_id`, so this reviewer entry isn't what satisfies that specific gate — the evaluator's
   own log call is. Log it anyway: it's the complete audit trail of which subagents actually ran
   this sprint, not just the one the close gate happens to check.

   **What to pass for `<id>`:** see shared gate mechanics (e) above.

3. **Evaluator review (normal+ tier).** Same `Tier: trivial` downgrade condition and exclusion
   as the reviewer gate above (skip only if `plan.md`'s `## Sign-off` `Tier:` field value is
   `trivial`, which can never apply to `SKILL.md`'s four categorical not-trivial triggers). For
   normal and high-risk sprints, always spawn a freshly invoked Agent subagent for the
   evaluator review, per the shared gate mechanics above.

   Evaluator needs a fresh context, no implementation history, grading adversarially against
   `acceptance.md`. Same-context review, self-review, or "reviewed directly because delegation
   needs approval" is not acceptable for normal/high-risk sprints. If the runtime can't spawn
   the evaluator subagent, stop closeout and report the blocker.

   **Retry budget.** Before dispatching, read `eval_fail_count` from `.tickets/<id>/ticket.md`
   (absent on tickets predating this field means 0). If it is already 3, do not dispatch
   another evaluator subagent. Instead, stop here and tell the human explicitly:
   "Evaluator has failed 3 times in a row — retry budget exhausted. Either diagnose the root
   cause outside this automated loop, or set `eval_override: true` with a dated waiver (see
   acceptance.md) to close anyway." This is a soft, informational nudge against blind
   auto-retries on a stubborn finding — it does not change `_gate_eval_report_verdict`'s close
   gate mechanics or add a second enforcement layer on top of `eval_override`, which stays the
   sole, intentionally human-only escape hatch.

   Invoke a fresh Agent subagent with a clean context, per the model-tier check above. Pass
   `subagent_type: "Plan"`, same restriction and rationale as the reviewer gate above. Prompt
   must instruct it to:
   - Read `skills/sprint/reference/eval.md` and follow the eval protocol
   - Record its model designation per the shared gate mechanics above
   - Write its report to `.tickets/<id>/eval-report.md` and return the verdict line

   **If the subagent's Bash refused to write the file:** see shared gate mechanics (f) above.
   Check whether `.tickets/<id>/eval-report.md` exists after dispatch; if not, save the
   returned report text yourself.

   **Record the verdict.** Immediately after reading `.tickets/<id>/eval-report.md`'s verdict
   line, run `sprint eval-verdict <id>` (bare — it's on PATH, same as `sprint`/`tkt`). This
   writes the outcome into `ticket.md`'s `eval_fail_count` field — incrementing on `fail`,
   resetting to `0` on `pass` — so the retry-budget check above sees real state on the *next*
   `sprint complete` invocation, regardless of whether this one goes on to reach step 9's CLI
   call. Do this even when the verdict is `pass`, to reset the counter. See
   `standards/ticket-layout.md`'s `eval_fail_count` field contract for the full mechanics.

   **Log the subagent run.** Immediately after the evaluator subagent completes, read the
   `evaluator-run-id:` field it wrote as the first line of `.tickets/<id>/eval-report.md`, then
   run `subagent-log.sh --agent-id <evaluator-run-id> --agent-type evaluator` (bare — it's on
   PATH, same as `sprint`/`tkt`). `sprint complete`'s close gate (`_gate_eval_report`)
   hard-fails if `.claude/subagent-runs.jsonl` exists but has no entry within ±60 minutes of
   that `evaluator-run-id` — this CLI call is what satisfies that check now that no hook does it
   automatically. Skipping it risks a confusing close-time failure on an otherwise-passing
   sprint.

   **What to pass for `<id>`:** see shared gate mechanics (e) above. For the evaluator
   specifically, reusing the `evaluator-run-id` (from the report's first line) is the
   recommended value — it ties the audit line to the exact run recorded in the report.

   Read `.tickets/<id>/eval-report.md` after the subagent completes and close its handle per
   the shared gate mechanics above. Surface any `fail` findings to the user before proceeding
   — this includes any report where individual criteria/test-plan items graded `partial`,
   since `eval.md` requires the verdict line to be `fail:` whenever a partial exists (there is
   no separate non-blocking `partial:` verdict). Do not advance to step 4 if the evaluator
   verdict is `fail` — **unless** `ticket.md` has `eval_override: true` set and
   `acceptance.md` records at least one dated waiver (the coarse check `_gate_eval_report`
   also enforces mechanically). Read this field; never write `true` to it — `tkt create` seeds
   every ticket with `eval_override: false`, but no `tkt` command ever sets it `true`, and an
   agent must not hand-edit `ticket.md` to flip it even if the user asks directly (see
   `standards/ticket-layout.md`'s field contract). **Activation path:** only a human may
   hand-edit `ticket.md` to set `eval_override: true`, outside of any agent session — this is
   intentionally high-friction and auditable. The override does NOT mean every failing
   item is automatically covered — steps 4-5 below still individually confirm, per item,
   which specific failures are genuinely waived versus real defects; a mechanical per-item
   check was tried and abandoned as unsound across five rounds of adversarial review (see
   `DECISIONS.md`, `t-c0e6`) — this human judgment is the actual verification, not a
   formality. If the override applies, record it explicitly in the Wrapup Gates table's
   Reason (e.g. `verdict: fail — closed under eval_override=true, see acceptance.md`) and in
   `summary.md`, so the reliance is greppable later — never silently proceed as if the
   verdict were `pass`. Record the eval outcome in the Wrapup Gates table with the Reason
   prefixed `verdict:` (e.g. `verdict: pass` or `verdict: fail — <one-line summary>`).

4. **Test verification.** Review each item in `acceptance.md ## Test Plan`:
   - **Coverage check, before grading individual items.** Confirm every `acceptance.md ## Criteria`
     item has at least one `## Test Plan` line that actually exercises it — not just restates
     it. Treat missing coverage as a blocking gap: do not proceed until a real test-plan item
     is added and run.
   - ✓ passed | ✗ failed | ? not run (maps to `eval.md`'s `pass`/`fail`/`not-run` — same three
     states, different notation since this step is a human-facing recap, not the evaluator's
     own report format)
   - If any ✗ or ?: report which tests did not pass. Do not close the ticket. Stop here.
   - Include impact and regression tests.
   - Classify required evidence for each item. Load-bearing test/tool evidence must fail closed
     when unavailable; preferred evidence may degrade with disclosure; decorative evidence can
     be dropped. Cached evidence counts only when source, timestamp/version, freshness window,
     and why that freshness is acceptable are stated.
   - Confirm test results are documented in `acceptance.md` (pass/fail per item, date run, and
     the evidence checked).
   - Proceed only when all tests are ✓ or explicitly waived by the user with a documented
     reason.

5. **Acceptance check.** Review each item in `acceptance.md`, including `## QA`'s "Tested
   locally" checkbox — the evaluator does not grade QA (see `eval.md`'s Gotchas); this step is
   where a human confirms it reflects real verification, not just a checked box:
   - ✓ met | ✗ not met | ? uncertain
   - If any ✗: report what is missing. Do not close the ticket. Stop here.
   - Do not mark an item met from weak evidence: empty or stale output, no stated search scope,
     vague prose, uninspected generated output, or citations that do not point to changed or
     directly relevant files.
   - Proceed only when all criteria are ✓ or explicitly waived by the user.

6. **DECISIONS.md.** Append any durable decisions made during this sprint — non-obvious
   architectural choices, explicit tradeoffs, out-of-scope calls. One row per decision. Write
   the WHY, not the what. Skip if no new decisions were made. If this sprint's decision cleanly
   supersedes or retires an *entire* earlier entry (not a fragment of a composite, multi-topic
   one), move that earlier entry's row to `DECISIONS-archive.md` instead of leaving it in
   `DECISIONS.md` forever — this is what keeps the file `sprint start` actively scans from
   growing unbounded. Never split a multi-topic entry to archive part of it.

7. **Conventions.** While context is fresh: did any convention-level learning emerge — pattern,
   naming norm, non-obvious file relationship, gotcha — worth a future agent knowing? Distinct
   from decisions: a decision is "we chose X"; a convention is "X always lives next to Y" or
   "never touch Z without also updating W."
   - Yes: propose the addition (one or two lines) and the target file (`AGENTS.md`,
     `CLAUDE.md`, or a subdirectory `CLAUDE.md` if one exists). Confirm with the user before
     writing.
   - No: skip silently.

8. **Summary.** Write `.tickets/<id>/summary.md` with the plan-vs-actual table and a
   one-paragraph summary. Also output both in chat.

   File format:
   ```markdown
   # Summary

   | Acceptance item | Status | Notes |
   |---|---|---|
   | <criterion verbatim> | delivered / waived / deferred / partial | reason if not delivered |

   <one paragraph: what shipped, test results, any waived/deferred items and why, follow-up recorded. For normal+ tier, name which model the reviewer/evaluator gates ran on (pulled from the Wrapup Gates table's `(model: <model>)` suffix) — e.g. "reviewer and evaluator ran on haiku (low-risk classification).">
   ```

   One row per acceptance criterion from `acceptance.md`. Deviations must appear in the table
   — do not bury them in prose. The file appears as a **Summary** tab on the ticket board
   alongside Acceptance and Plan. If a criterion contains a `|`, write it as `\|` — bare pipes
   break the board's table renderer.

9. **Close.** Run `sprint complete` — never write `ticket.md` status directly. If it refuses
   because a required file is missing or checklist items remain unchecked, report the blockers
   and stop.

10. **Commit & Push.** Always run this at the end, once close succeeds — even if no code
    changed (docs and config still need committing). This step owns Commit & Push — wrapup's
    own pipeline (step 1) never commits, because `DECISIONS.md`/`HANDOFF.md`/`summary.md` are
    written by steps 6-8, after wrapup finishes; committing any earlier would miss them.
    - List all modified and untracked files (`git status`). Stage only the files relevant to
      this session's work — never `git add -A`.
    - Draft a commit message per `standards/efficiency.md`'s Git conventions: imperative mood,
      type prefix, 50-char target / 72-char hard limit, no trailing period. Every sprint-backed
      commit includes `Closes: t-xxxx` in the body — this step always has the ticket ID in
      hand. Add more body for breaking changes or non-obvious reasoning.
    - Show the staged files and commit message. Ask: **"Commit and push? (y to proceed)"**
    - On yes: commit, then push to the current branch's remote. Report the pushed ref.
    - If criticals from the review pipeline are unresolved: warn before asking — do not block,
      but make the risk explicit.
