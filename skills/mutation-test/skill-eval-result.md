## Skill Eval: mutation-test
Run: 2026-07-25

### Structural check
Body: pass — body within threshold (106 lines; threshold: 500 — standalone)
Evals: pass — 4 eval cases

### Case 1: control — surviving mutant in a tautological test
- "Applies a mutation from the skill's set to the logic file (not test file)" → pass
  Evidence: allowlist drops tests/test_offline.py; mutations applied to button_disabled one per run.
- "Identifies the mutant SURVIVES because the test re-derives its expected value" → pass
  Evidence: "the expected value is derived from the same data the function uses, so the assertion can never disagree."
- "Labels the surviving mutant a 'test that cannot fail'" → pass
  Evidence: "A surviving mutant = a test that cannot fail (decoration)."
- "Reports advisory, does not claim to block close" → pass
  Evidence: "Skill is advisory-only; does not block close."

### Case 2: boundary — docs/config/test-only diff
- "Recognizes none are production logic files" → pass
  Evidence: "Zero production logic files survived the allowlist."
- "Explicitly skips docs, config, test files" → pass
  Evidence: per-file skip verdicts for README/docs/config/test.
- "Does not apply any mutation" → pass
  Evidence: "the mutation loop never executed... Working tree untouched."
- "Reports nothing to mutation-test rather than proceeding" → pass
  Evidence: "NO LOGIC FILES CHANGED — clean stop."

### Case 3: compliance — the mutate/restore loop
- "Restores the mutated file unconditionally (pass/fail/error)" → pass
  Evidence: step 5 "Restore original bytes UNCONDITIONALLY ... regardless of pass/fail/error."
- "Runs the suite between applying the mutation and restoring" → pass
  Evidence: order apply→run→record→restore.
- "Ends with clean-tree verification and restores via git if dirty" → pass
  Evidence: "git status --porcelain ... must be empty; if dirty, git checkout -- before reporting."
- "States the run is isolated (fresh subagent)" → pass
  Evidence: "dispatch as fresh Plan subagent (never mutate in main session)."

### Case 4: edge — stale bytecode false verdict
- "Identifies stale bytecode/__pycache__ as the likely cause" → pass
  Evidence: names "STALE BYTECODE"; explains pytest importing a cached .pyc compiled from the mutated source.
- "Clears cache / forces recompilation" → pass
  Evidence: remove __pycache__/*.pyc; python -B / PYTHONDONTWRITEBYTECODE=1.
- "Re-verifies the mutation state is live before trusting the verdict" → pass
  Evidence: cache-cleared baseline + confirms correct file imported (calc.__file__/__cached__).

### Summary
15/15 expectations passed
Verdict: pass

Note: Case 4's first run scored 2/3 (partial) on an ambiguous scenario ("every mutation killed"),
which a reasonable executor also attributed to a missing green baseline. The prompt was sharpened
so stale bytecode is the unambiguous cause (restored, git-clean source still fails as if mutated);
re-run scored 3/3.

### Issues
| Issue | Details | Reason |
|---|---|---|
