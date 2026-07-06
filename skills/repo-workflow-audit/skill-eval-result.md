## Skill Eval: repo-workflow-audit
Run: 2026-07-06T00:00:00Z

### Structural check
Body: pass — body within threshold (46 lines; threshold: 500 — standalone)
Evals: pass — 6 eval cases

### Case 1: Run a repo-workflow-audit on a fictional skill family at ski
Not re-run via executor+grader this pass (unchanged by this ticket's edit) — see Regression note below. Last full run 2026-07-03: 5/5 expectations passed.

### Case 2: Run a repo-workflow-audit with no target specified.
Not re-run via executor+grader this pass (unchanged by this ticket's edit) — see Regression note below. Last full run 2026-07-03: 3/3 expectations passed.

### Case 3: During a repo-workflow-audit, one dispatch finds that a doc
Not re-run via executor+grader this pass (unchanged by this ticket's edit) — see Regression note below. Last full run 2026-07-03: 3/3 expectations passed.

### Case 4: Run a repo-workflow-audit on skills/sprint/**. The target's
Not re-run via executor+grader this pass (unchanged by this ticket's edit) — see Regression note below. Last full run 2026-07-03: 3/3 expectations passed.

### Case 5: Run a repo-workflow-audit on a fictional skill at skills/status
- "Describes running all four dispatches rather than replacing the audit structure with a prose-only review" → pass
  Evidence: Executor lists Dispatch 1, 2, 3, 4 explicitly, each with distinct findings.
- "Flags repeated wording or duplicated instruction as a lean-language finding" → pass
  Evidence: Finding "[High] Lean-language: triple restatement" — three lines "encode the identical constraint."
- "Flags unnecessary filler or prose bloat as a lean-language finding" → pass
  Evidence: Finding "[High] Lean-language: filler paragraph... asserts no rule, only motivates already-stated rules — delete."
- "Produces or describes producing an actual candidate compressed rewrite, not just a flag" → pass
  Evidence: Candidate rewrite given verbatim: "## Output Rules\n\nKeep status output concise."
- "Reports old/new word counts as evidence of the compression" → pass
  Evidence: "Confirmed word counts: 133 → 7 words," stated twice.
- "Recommends simpler straight-to-the-point wording only where intent remains clear and correct" → pass
  Evidence: Rewrite preserves "be concise" intent while dropping redundant/filler wording; executor states intent "is fully preserved."

6/6 expectations passed.

### Case 6: During a repo-workflow-audit, the user approves a comp
- "States that npm test passing and a clean stale-reference grep are not sufficient to consider a compression fix done" → pass
  Evidence: "npm test passing and a clean stale-reference grep are necessary but insufficient for a compression edit."
- "States a fresh-context subagent must diff old vs. new line-by-line for dropped or weakened rules/cases/templates" → pass
  Evidence: "dispatch a fresh-context subagent with review purpose whose only job is to diff the old paragraph against the new one, line-by-line."
- "Frames this as an additional requirement specific to compression fixes, not a replacement for the existing test/grep re-verify step" → pass
  Evidence: "after re-verifying with npm test and a fresh grep sweep, it states — 'that re-verify step isn't enough.'"
- "Does not declare the compression fix done without this diff-verification step" → pass
  Evidence: "No, the fix is not done... only done after a fresh-context reviewer subagent has diffed old vs. new... reports zero findings."

4/4 expectations passed.

### Regression note (cases 1–4)
Cases 1–4 test dispatch count/naming ("four dispatches"), default target scope, no-auto-fix framing, and the cheap-model override — none of which this ticket's edit touches. Verified structurally rather than re-running full executor+grader: `grep -n "four dispatches\|4-way\|4 dispatches\|5 dispatches\|five dispatches"` across `SKILL.md` and `evals.json` confirms the count and wording are unchanged (still "4"/"four" everywhere, no accidental renumbering), and the new text (dispatch #2's compression-candidate instruction, "Compile, don't auto-fix"'s compression-verify paragraph) is additive — it doesn't remove or alter the sentences those 4 cases assert against.

### Summary
10/10 expectations passed (cases 5–6, full executor+grader run this pass); cases 1–4 verified structurally unaffected (last full run 2026-07-03: 14/14 passed).
Verdict: pass

### Issues
| Issue | Details | Reason |
|---|---|---|
| Cases 1–4 not re-run via executor+grader this pass | Verified via structural grep instead (see Regression note) | Cost/scope tradeoff — recommend a full 6-case run before the next repo-workflow-audit invocation on a real target |
