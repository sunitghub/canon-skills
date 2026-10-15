---
name: mutation-test
description: Generates mutants over a sprint's changed lines (mutant-sweep) and triages every survivor — a surviving mutant is a test that cannot fail. Use when asked to mutation-test, check whether tests have teeth, or find tests that pass no matter what the code does. Advisory, not a close gate.
category: dev
tags: [testing, quality, mutation-testing, verification]
hidden: true
---

# Mutation Test

Operationalizes canon's thesis that **"the tests pass" is a claim that needs its own evidence.**
Break the code on purpose: flip a boolean, negate a conditional, delete a statement — then run the
suite. If nothing fails, the test was decoration. A surviving mutant is a **test that cannot fail.**

This is **advisory, not a gate.** It reports surviving mutants; it never blocks `sprint complete`.
It **complements, does not replace, the fresh-context evaluator**: the evaluator checks acceptance
criteria against the code; mutation-test checks whether the tests protecting that code have teeth.

## Run the sweep, on changed lines only

`mutant-sweep` (bare, on PATH like `sprint`; `tools/mutant-sweep` in canon; needs `python3`) generates
the mutants; do not pick them by hand (hand-picked sets missed the gaps that cost `t-b860` three
failed evaluator runs). Run it from the project root:

```bash
mutant-sweep --map <logic file>=<test command> [--map ...] --report .tickets/<id>/mutation-report.md
```

- **Logic files only.** Map production shell/JS files from the sprint diff; never docs, config,
  generated files or the tests themselves (mutating a test proves nothing). If the diff changed no
  logic file, report "no logic files changed" and stop.
- **One `--map` per changed logic file**, naming the test command that covers it: take it from
  `acceptance.md ## Test Plan` and the tests changed alongside. The tool never guesses: a changed
  shell/JS file with no `--map` is listed `unmapped`, so a gap shows instead of passing silently.
- **Scope = changed lines.** Only lines added or changed since `git merge-base HEAD origin/main`
  (`--base <ref>` to override) are mutated. A failed merge-base exits 2 and runs nothing.
- **Shell and JS only** (`bash -n` / `node --check` drop mutants that do not parse, reported
  `INVALID`); any other mapped file is listed `unsupported`.
- **Operators** (one fixed table in the tool, applied at every occurrence): comparison and
  `&&`/`||` flips, off-by-one, `true`/`false`, negation removal, return/exit codes, sort/unique
  removal, a dropped `&&`/`||` operand, a dropped regex anchor, a widened pattern, an emptied
  string constant, and whole-line deletion.
- **Isolation.** Every mutant runs in a fresh copy of the project (tracked + untracked files, no
  `.git`) with its own `TMPDIR`, `CANON_HOME` and `XDG_CONFIG_HOME`; the real tree is never written.
  Each test runs in its own process group, killed after it exits or times out (`--timeout`, default
  300 s); Ctrl-C/TERM stops every test and removes the temp root. So it runs inline, not in a
  dispatched subagent.
- **Baseline.** Each test command first runs on an unmutated copy; if it fails there (for example
  it needs the project's `.git`), the tool stops with `baseline fails: <cmd>` instead of reporting
  false kills. Map a test that does not need git history, or note the file as not swept.

Verdicts: `KILLED` (the test failed with a `FAIL`/`not ok` line, quoted), `KILLED(crash)` (failed
without one), `KILLED(timeout)`, `SURVIVED`, `INVALID`. The tool exits 0 after a sweep.

## Triage every survivor

A surviving mutant is a place where the code can be broken and no test complains. For each one,
before the reviewer and evaluator run:

1. **Fix a test** — state the expectation independently (see README's "test that could not fail"
   example) so the mutant fails it, then re-run the sweep; or
2. **Delete a redundant check** the mutant shows does nothing; or
3. **Mark it equivalent, with a reason** (why no input can tell the mutant from the code).

Append the triage under the tool's table in `.tickets/<id>/mutation-report.md`:

```markdown
## Triage
- tools/foo.sh:42 `cmp: == -> !=@14` — fixed: tests/foo.sh pins the `==` branch.
- tools/foo.sh:55 `delete-line` — equivalent: the `if` above already returns 0.
```

If zero mutants survive, say so — that is a passing signal, not a no-op. Advisory only: it never
blocks close.

## Promotion path (out of scope here)

This skill ships advisory-first by design. Promoting it to a **close gate** is deliberately
deferred: do it only once the false-positive rate is known from real runs, and only for
logic-bearing changes — gated by a structural path check (the close-gate model tier once
used a docs-only allowlist for this; `skills/sprint/reference/complete.md` retired it in
`t-4b5a`, so any promotion would need its own). Until then, no `tools/sprint`
`_gate_*` function references this skill.

## Gotchas

- **A survivor on a line the diff did not change cannot appear** — only changed lines are mutated.
  A guard the sprint relies on but did not touch needs its own revert test.
- **Slow tests.** Every mutant runs its mapped command once; map the narrowest test that covers the
  file, not the full suite.
- **Flaky tests** produce false kills. If a kill cannot be reproduced, treat it as survived and flag
  the flake.
- **A test that starts a process in a new session** (`setsid`, a daemon that detaches) leaves the
  test's process group, so the tool cannot stop it; such a test must stop its own children.
