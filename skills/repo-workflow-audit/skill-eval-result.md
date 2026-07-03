## Skill Eval: repo-workflow-audit
Run: 2026-07-03T11:00:00-05:00

### Structural check
Body: pass — body within threshold (42 lines; threshold: 500 — standalone)
Evals: pass — 5 eval cases

### Case 1: Run a repo-workflow-audit on a fictional skill family at ski
- "Describes running all four dispatches (pipeline gates, adversarial review, cross-doc consistency, stale-reference sweep) independently" → pass
  Evidence: Executor simulated four fresh-context dispatches and named all four checks.
- "Flags the six-step claim vs. 5 actual listed steps as a finding" → pass
  Evidence: Executor flagged the "six-step" vs five listed steps contradiction as medium severity.
- "Flags the reference to the deleted scripts/build-legacy.sh as a stale reference" → pass
  Evidence: Executor flagged deleted `scripts/build-legacy.sh` as a high-severity stale reference.
- "Presents compiled findings to the user before making any fix" → pass
  Evidence: Executor compiled and deduped findings before any fix.
- "Does not silently edit skills/deploy files without presenting findings first" → pass
  Evidence: Executor explicitly said no fixes were applied and no files were edited.

### Case 2: Run a repo-workflow-audit with no target specified.
- "States or uses skills/sprint/** and skills/wrapup/** as the default target when none is given" → pass
  Evidence: Executor used default scope `skills/sprint/**` + `skills/wrapup/**`.
- "Does not block or refuse to proceed for lack of an explicit target" → pass
  Evidence: Executor returned findings and did not refuse for missing target.
- "Still describes running all four dispatches against the defaulted target" → pass
  Evidence: Executor said it would run four fresh-context agents: pipeline gates, adversarial review, cross-doc consistency, stale-reference sweep.

### Case 3: During a repo-workflow-audit, one dispatch finds that a doc
- "States findings must be compiled and presented to the user before any fix is applied" → pass
  Evidence: Executor quoted "Compile, don't auto-fix" and "Present the full compiled list to the user before applying any fix."
- "Does not describe fixing the stale-command finding automatically without user direction" → pass
  Evidence: Executor said status was not fixed and no file edits/tool calls occurred.
- "Frames fixing as a separate, explicit step scoped by the user" → pass
  Evidence: Executor said fixing requires separate explicit user instruction.

### Case 4: Run a repo-workflow-audit on skills/sprint/**. The target's
- "States the audit does not apply the target's own cheap-model/blast-radius shortcut to itself" → pass
  Evidence: Executor said the audit must not use the target cheap-model rule.
- "States all four dispatches run on the strongest available model" → pass
  Evidence: Executor said all four dispatches run strongest available model.
- "Explains this is because the audit is deliberately high-scrutiny work" → pass
  Evidence: Executor explained auditing that shortcut is part of the audit's job.

### Case 5: Run a repo-workflow-audit on a fictional skill at skills/status
- "Describes running all four dispatches rather than replacing the audit structure with a prose-only review" → pass
  Evidence: Executor simulated the required 4-way fresh-context audit.
- "Flags repeated wording or duplicated instruction as a lean-language finding" → pass
  Evidence: Executor flagged repeated concise-output wording as lean-language bloat.
- "Flags unnecessary filler or prose bloat as a lean-language finding" → pass
  Evidence: Executor flagged the filler prose about concise communication as redundant and bloated.
- "Recommends simpler straight-to-the-point wording only where intent remains clear and correct" → pass
  Evidence: Executor recommended `Keep output concise` as a later approved fix while preserving the correct intent.

### Summary
19/19 expectations passed
Verdict: pass

### Issues
| Issue | Details | Reason |
|---|---|---|
