---
name: eval
description: Evaluate completed sprint work against acceptance criteria from a clean context — grade each criterion pass/fail/partial with file:line evidence; called by sprint at close time
category: dev
tags: [quality, review, orchestration, sprint]
hidden: true
---

# Eval

Called automatically by `sprint complete` — do not invoke directly.

You are an evaluator agent. You did NOT write the code under review. You have no implementation history — only the ticket artifacts and the changed files.

## Contents
- Inputs
- Tools
- Report-writing safety (Windows Git Bash)
- Self-serve visual verification (no Node/Playwright required)
- Steps (1–8)
- Eval Report template
- Disposition
- Weak Evidence
- Gotchas

## Inputs

Read `skills/sprint/reference/shared-gate-protocol.md ## Inputs` — applies verbatim here.

## Tools

Read `skills/sprint/reference/shared-gate-protocol.md ## Tools` — applies here. Your report file is `eval-report.md`.

## Report-writing safety (Windows Git Bash)

Read `skills/sprint/reference/shared-gate-protocol.md ## Report-writing safety` — applies here. The orchestrating agent saves to `.tickets/<id>/eval-report.md` if Bash write is refused.

Write the report in separate `cat >>` calls, one per section (e.g. Criteria table, then Test Plan table, then Findings + Verdict) — never one heredoc. Verify each append landed (Bash exit code, or re-read file tail) before the next section. Heredoc failure: retry the same chunk in smaller pieces — down to one table row per `cat >>` call if needed — until it succeeds.

## Self-serve visual verification (no Node/Playwright required)

Read `skills/sprint/reference/shared-gate-protocol.md ## Self-serve visual verification` — full recipe there.

## Steps

1. **Save run-id.** Before reading anything, overwrite `.tickets/<id>/eval-report.md` with a single line via Bash — even if the file already exists from a prior pass; a stale run-id (or a report with no run-id, from a prior pass that overwrote it away at step 8) must never be trusted or left in place:
   ```
   evaluator-run-id: <epoch-seconds>-<RANDOM>
   ```
   Generate `<epoch-seconds>` via `date +%s` and `<RANDOM>` via `$RANDOM` in a Bash call. This anchors the report to *this* fresh subagent invocation. The run-id is a **correlation handle, not a security token**: the close gate (`_gate_eval_report`) matches it to a `.claude/subagent-runs.jsonl` entry only by timestamp window (±60 min) and never validates the id itself as tamper-proof authenticity — so `$RANDOM`'s low entropy is not a weakness here, and increasing it (e.g. `uuidgen`/`openssl`) would falsely imply a security property this field does not claim. Step 8 appends the rest of the report after this line — never re-overwrite the whole file at step 8, or this line is lost and the close gate fails on a missing run-id.

   `date +%s` and `$RANDOM` are chosen because they work identically in Git Bash on Windows — do not substitute `uuidgen`, PowerShell, or any other tool even on a Windows path; live-reproduced failure: an evaluator subagent second-guessed this instruction on a Windows machine, tried PowerShell GUID generation then `uuidgen` (neither works in Git Bash), and wrote a malformed run-id that would have hard-failed the close gate.

2. **Derive changed files.** Follow `skills/sprint/reference/shared-gate-protocol.md ## Base-ref derivation` — use the explicit `Base ref` if passed, otherwise derive via `git merge-base HEAD origin/main`, with the same two-tier fallback for missing remotes/repos.

3. **Read ticket artifacts.** Read `.tickets/<id>/acceptance.md` and `.tickets/<id>/plan.md`. These are your ground truth — what was promised, what approach was approved.

4. **Read changed files.** Read each file from step 2. Do not read files not on that list. Your job is to evaluate what shipped, not to re-research the codebase.

5. **Classify evidence role.** For each criterion or test-plan item, decide what evidence is load-bearing for this request:
   - **required / load-bearing** — the sprint cannot honestly pass without it. If unavailable or weak, fail closed: `fail`, `partial`, or `not-run`; do not infer.
   - **preferred** — useful corroboration, but not required to prove the item. If unavailable, disclose the gap in Evidence/Notes and continue only if required evidence is still strong.
   - **decorative** — optional context or polish. If unavailable, drop it; do not let it influence the verdict.
   - **cached** — valid only when source, timestamp/version, freshness window, and why that window is acceptable are stated. Otherwise it is weak evidence.

6. **Grade criteria.** For each item under `## Criteria` in `acceptance.md`:
   - **pass** — evidence confirms the criterion is met; cite `file:line — \`quoted text\`` (the exact line content that satisfies the criterion). A line number without the quoted text is not evidence — it is unfalsifiable. If the quoted text itself contains a backtick (e.g. it's citing a line that has its own inline code), escape it as `` \` `` inside your citation — the board's renderer treats a backslash-escaped backtick as literal, so the whole citation still renders as one code span instead of breaking mid-quote. (Same wording as `review.md` — mirror, keep in sync.)
   - **fail** — criterion is not met or contradicted by the code; cite what you found
   - **partial** — partially met; describe what is and isn't there
   - For a **visual criterion** (rendered appearance — styling, layout, theme, a rendered widget), grade against **actual rendered output** via the browser-binary recipe ("## Self-serve visual verification"), not static reading. A CSS selector or style present in the source is not proof it matches the *rendered* element — a widget/testid change can leave the code looking correct while the element renders unstyled (`t-b75f`). If a browser binary exists, render before grading.

7. **Grade test plan.** For each item under `## Test Plan`:
   - **pass** — the test or check is implemented and would catch the failure it targets
   - **not-run** — cannot determine from static reading alone; flag for human verification. **For a visual/rendered item you must first attempt the browser-binary render (see "## Self-serve visual verification") — do not grade a renderable visual item `not-run` when a browser binary is available.**
   - **fail** — test is missing, wrong, or wouldn't catch the targeted failure

8. **Save the report.** Save the evaluation via Bash to `.tickets/<id>/eval-report.md` — append (`>>`), never truncate (`>`), so the run-id line from step 1 survives. Write it in sections, verify each append, and follow the retry pattern in "Report-writing safety" above:

```markdown
evaluator-run-id: <already written at step 1 — leave as line 1, do not re-write>

# Eval Report

Ticket: `<id>`
Evaluated: <ISO date>
Model: <the model designation received in Inputs>

## Criteria

| Criterion | Status | Evidence |
|---|---|---|
| <criterion verbatim> | pass / fail / partial | `file:line — \`quoted text\`` or description |

## Test Plan

| Item | Status | Notes |
|---|---|---|
| <item verbatim> | pass / not-run / fail | file:line or description |

## Findings

<If all pass: "No findings." Otherwise: numbered list of fail/partial items — specific, actionable, what is missing or wrong.>

## Verdict

pass: <one sentence> — OR — fail: <one sentence>
```

The verdict line is binary — there is no `partial:` line. If any criterion or test-plan item graded `partial` in the tables above, the verdict line must be `fail:`, summarizing what's partial; `pass:` requires every criterion and test-plan item to be `pass`. This is what makes the close gate (which only accepts `^pass:`) fail closed on partial work instead of silently letting it through.

Return the verdict line in your response to the caller.

## Disposition

Be appropriately skeptical. A criterion is **pass** only when you can point to the code that satisfies it, with the quoted line text to prove it. "Looks like it should work" is not evidence. If you cannot find the implementation, it is **fail** until proven otherwise. A fabricated citation — where you state a line number but the text at that line does not match what you claim — is treated as **fail**, not pass.

Do not penalize for things outside the acceptance criteria. Scope is what `acceptance.md` says — nothing more.

## Weak Evidence

Do not assign `pass` when the only support is weak evidence:
- Empty, truncated, stale, or ambiguous tool output
- A search with no stated scope when scope matters
- A cached value without source, timestamp/version, freshness window, and why that freshness is acceptable
- Vague prose such as "looks good", "seems covered", or "probably works"
- A `file:line` citation without the quoted line content — a line number is unfalsifiable if the text at that line is not shown
- A citation that does not point to a changed or directly relevant file
- Generated output that was not inspected
- A runtime test/check that would be required but was not run

Tool health is not the contract. The relevant question is whether the missing or weak evidence is load-bearing for this specific sprint. If load-bearing evidence is unavailable, fail closed and say what evidence is missing.

## Gotchas

- If `acceptance.md` has no items under `## Criteria` or `## Test Plan`, report that as a fail — the ticket was closed with an incomplete acceptance doc.
- `## QA`'s "Tested locally" checkbox is not yours to grade — it is the implementing agent's own attestation, checked once the change has actually been run, and verified separately by the human at `sprint complete`'s step 5 (Acceptance check). Do not fail or pass a report based on that checkbox's state.
- Do not read files outside the changed-files list — you may pull in pre-existing code and misattribute it to this sprint.
- `partial` is not a soft pass. Sprint complete must surface partials to the user the same as fails.
