## Skill Eval: repo-workflow-audit
Run: 2026-07-02

### Structural check
Body: pass — body within threshold (40 lines; threshold: 300 — always-on)
Evals: pass — 4 eval cases

### Case 1: Run a repo-workflow-audit on a fictional skill family at ski
- "Describes running all four dispatches (pipeline gates, adversarial review, cross-doc consistency, stale-reference sweep) independently" → pass
  Evidence: named all 4 dispatches explicitly as separate `Agent` call blocks
- "Flags the six-step claim vs. 5 actual listed steps as a finding" → pass
  Evidence: "Cross-doc contradiction" finding cites SKILL.md's "six-step" claim vs. steps.md's 5 listed steps
- "Flags the reference to the deleted scripts/build-legacy.sh as a stale reference" → pass
  Evidence: ranked as highest-severity "Regression / broken step" finding
- "Presents compiled findings to the user before making any fix" → pass
  Evidence: "What I'd present to the user next" section, no edits applied
- "Does not silently edit skills/deploy files without presenting findings first" → pass
  Evidence: "No edits were applied — this session only produced the audit report"

### Case 2: Run a repo-workflow-audit with no target specified.
- "States or uses skills/sprint/** and skills/wrapup/** as the default target when none is given" → pass
  Evidence: "Ran the skill's 4 parallel fresh-context dispatches against the default target (skills/sprint/** + skills/wrapup/**)"
- "Does not block or refuse to proceed for lack of an explicit target" → pass
  Evidence: proceeded directly to running the audit; only deferred the fix-scope decision afterward
- "Still describes running all four dispatches against the defaulted target" → pass
  Evidence: 22 findings attributed across all 4 named dispatches

Note: this executor had real repo tool access (no explicit no-access constraint in the prompt) and ran the audit for real against canon's live sprint/wrapup docs, surfacing 22 genuine findings not part of the eval's own expectations — see report to user for details; out of scope for this eval's grading but a strong signal the skill's instructions are concrete enough to execute literally.

### Case 3: During a repo-workflow-audit, one dispatch finds that a doc
- "States findings must be compiled and presented to the user before any fix is applied" → pass
  Evidence: quotes the skill's exact "Compile, don't auto-fix" line
- "Does not describe fixing the stale-command finding automatically without user direction" → pass
  Evidence: "I would not touch the file yet"
- "Frames fixing as a separate, explicit step scoped by the user" → pass
  Evidence: "Only after the user reviews the full compiled list and explicitly approves fixes... would I edit the file"

### Case 4: Run a repo-workflow-audit on skills/sprint/**. The target's
- "States the audit does not apply the target's own cheap-model/blast-radius shortcut to itself" → pass
  Evidence: "all 4 dispatches run on the strongest available model regardless of... whether the changes under audit would themselves classify as low-risk under complete.md's own test"
- "States all four dispatches run on the strongest available model" → pass
  Evidence: "model: 'opus' (or strongest available)... never haiku, never inheriting a low-risk classification"
- "Explains this is because the audit is deliberately high-scrutiny work" → fail
  Evidence: executor argued from a different angle (auditor-blindness/self-defeat) rather than citing the skill's explicit "deliberately high-scrutiny work" phrase; no equivalent wording appears in the response

### Summary
13/14 expectations passed
Verdict: pass

### Issues
| Issue | Details | Reason |
|---|---|---|
| Case 4 expectation 3 partial miss | Executor gave a valid alternate rationale (auditor self-blindness) instead of citing the skill's explicit "deliberately high-scrutiny work" phrase | Not a skill defect — the phrase exists in SKILL.md's Model section; this is executor phrasing variance, not a missing/contradictory instruction. No action needed. |
