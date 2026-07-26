---
name: mutation-test
description: Applies small logic mutations to a sprint's changed logic files and asserts the test suite fails on each — a surviving mutant is a test that cannot fail. Use when asked to mutation-test, check whether tests have teeth, or find tests that pass no matter what the code does. Advisory, not a close gate.
category: dev
tags: [testing, quality, mutation-testing, verification]
---

# Mutation Test

Operationalizes canon's thesis that **"the tests pass" is a claim that needs its own evidence.**
Break the code on purpose: flip a boolean, negate a conditional, delete a statement — then run the
suite. If nothing fails, the test was decoration. A surviving mutant is a **test that cannot fail.**

This is **advisory, not a gate.** It reports surviving mutants; it never blocks `sprint complete`.
It **complements, does not replace, the fresh-context evaluator**: the evaluator checks acceptance
criteria against the code; mutation-test checks whether the tests protecting that code have teeth.

## Run isolated, on changed logic files only

- **Dispatch as a fresh subagent** (`subagent_type: "Plan"`, same posture as the reviewer/evaluator
  gates). Mutating source in the main session dirties the tree that session will commit — never do
  that inline. The subagent mutates and restores within its own turn.
- **Scope = the sprint diff.** Target set is
  `git diff --name-only $(git merge-base HEAD origin/main) HEAD`. Check `git merge-base`'s **exit
  status**, not whether the output is empty — a failed base resolution must mean "run nothing," not
  "mutate everything." If it fails or the diff is empty, report "no changed files to mutation-test"
  and stop.
- **Logic files only (allowlist posture).** From that set, keep only production logic files. Skip
  docs/markdown, config, generated files, and **test files themselves** — mutating a test proves
  nothing. On any doubt about whether a file is logic-bearing, **skip it** — never mutate an
  unrecognized shape. If nothing survives the filter, report "no logic files changed" and stop.

## Mutation set

Apply these one at a time, one mutation per run of the suite. This is the default set — do not
expand it into a menu:

1. **Flip a boolean/comparison operator** — `==`↔`!=`, `<`↔`>=`, `<=`↔`>`, `&&`↔`||`, `true`↔`false`.
2. **Negate a conditional** — wrap an `if` test in a logical negation.
3. **Swap an arithmetic operator** — `+`↔`-`, `*`↔`/`.
4. **Replace a return value** — return a default/zero/empty value instead of the computed one.
5. **Delete a statement** — remove one side-effecting line.

Mutate only logic-bearing lines in the changed hunks. A handful of high-value mutations per file
beats exhaustive coverage — this is a signal, not a certifier.

## The loop (follow exactly)

For each candidate mutation, in order — this sequence is fragile; a skipped restore corrupts the
working tree:

1. **Save** the target file's original bytes (copy to a scratch location, or note the exact hunk).
2. **Apply** one mutation.
3. **Run the suite** (the project's own command — e.g. `npm test`, `pytest`, `./scripts/test.sh`).
4. **Record** the outcome: suite **fails** → mutant *killed* (good); suite **passes** → mutant
   *survived* (a test that cannot fail — report it).
5. **Restore** the original bytes **unconditionally** — whether step 3 passed, failed, or errored.
   Never leave a mutation in place between iterations.
6. Move to the next mutation.

**End-of-run guarantee.** After the last mutation, verify the tree is clean:
`git status --porcelain` on the mutated files must be empty. If anything is dirty, restore it with
`git checkout -- <file>` before reporting. Do not finish on a dirty tree.

## Report

Advisory output — surface to the user, and when running inside a sprint also write
`.tickets/<id>/mutation-report.md`:

```markdown
# Mutation Report

| File:line | Mutation | Suite result | Verdict |
|---|---|---|---|
| src/foo.js:42 | `==` → `!=` | passed | SURVIVED — test cannot fail |
| src/foo.js:55 | deleted return | failed | killed |

Surviving mutants: N. Each is a place where the code can be broken and no test complains —
state the expectation independently (see README's "test that could not fail" example) so the
check can fail. Advisory only; does not block close.
```

If zero mutants survive, say so — that is a passing signal, not a no-op.

## Promotion path (out of scope here)

This skill ships advisory-first by design. Promoting it to a **close gate** is deliberately
deferred: do it only once the false-positive rate is known from real runs, and only for
logic-bearing changes — gated by the same structural low-risk path check the close-gate
model-downgrade uses (`skills/sprint/reference/complete.md`). Until then, no `tools/sprint`
`_gate_*` function references this skill.

## Gotchas

- **Stale bytecode = false "survived".** Mutating a compiled/cached-language file (Python
  `__pycache__/*.pyc`, and similar) then restoring the source can leave the test runner executing
  the *old* compiled bytecode — the mutation never actually ran, so a real hole looks "killed" or a
  killed mutant looks "survived." Clear the cache between mutation and re-run
  (`find . -name '__pycache__' -type d -prune -exec rm -rf {} +` for Python), or run the suite in a
  mode that recompiles from source. Verify the mutation is actually live before trusting the verdict.
- **Slow suites.** A full suite per mutation is expensive. Prefer running only the tests covering the
  mutated file when the project supports targeted runs; fall back to the full suite otherwise.
- **Flaky tests** produce false kills (a mutant "killed" by flakiness, not by a real assertion).
  If a mutation's kill can't be reproduced, treat it as survived and flag the flake.
- **Never commit a mutation.** If the session is interrupted mid-loop, the working tree may hold a
  live mutation — run `git status` and restore before any commit.
