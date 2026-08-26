---
name: dead-code-cleanup
description: Scans a repo for likely-unreferenced top-level symbols (JS/TS exports, Python def/class, Go exported func) and reports them as removal candidates. Use when asked to find dead code, unused exports, or unreferenced functions, or to clean up a codebase. Advisory-first — never deletes without explicit confirmation.
category: dev
tags: [cleanup, code-quality, dead-code, verification]
---

# Dead Code Cleanup

Finds code that nothing calls and reports it — it does not delete anything on its own.
Complements `mutation-test` (which checks whether *existing* tests have teeth): this skill checks
whether the code those tests cover is still reachable at all.

**Advisory-first, manual-trigger only.** No scheduling, no auto-PR, no auto-delete. Removal, once
the user confirms a candidate, is a normal code edit that goes through the sprint's existing
review/eval gates like any other change — this skill never bypasses them.

## Scope

- Default scope is the repo root (`git rev-parse --show-toplevel`). A user-supplied path or glob
  narrows it.
- Always exclude `node_modules`, `.git`, `dist`, `build`, `__pycache__`, and any vendor directory.
- If scope resolution fails (not a git repo, or `git rev-parse` errors), report that and stop —
  never fall back to scanning an unbounded filesystem path.

## The scan (follow exactly)

1. **Extract candidate declarations.** Grep-based, one pattern set per extension present in
   scope:
   - JS/TS (`.js`, `.ts`, `.jsx`, `.tsx`): `export (function|const|class) <Name>`
   - Python (`.py`): top-level `def <name>` / `class <Name>` not prefixed with `_`
   - Go (`.go`): `func <Name>(` where `<Name>` starts with an uppercase letter (exported),
     excluding `Test*`/`Benchmark*`/`Example*` (test-runner convention, not a static reference —
     see Gotchas)

   Skip any extension not in this list — do not guess a pattern for an unfamiliar language.

2. **Count references.** For each candidate symbol, `grep -rnw` the symbol across the scope,
   excluding the declaration's own line. Zero other matches anywhere in scope → dead-code
   candidate.

3. **Classify confidence.**
   - **High** — zero other references, and the declaring file is not an entry-point pattern.
   - **Low** — zero other references, but the declaring file matches an entry-point pattern:
     `index.*`, `__init__.py`, `main.go`, `cli.*`, or any file a `package.json`/shebang/build
     config names directly. These are likely public API surface or process entry points invoked
     by name from outside grep's reach — flag them, don't bury them, but don't recommend removal.

4. **Report.** Advisory table, one row per candidate — do not edit any file during the scan:

   ```markdown
   # Dead Code Report

   | File:line | Symbol | Kind | Confidence | Reason |
   |---|---|---|---|---|
   | src/foo.js:12 | oldHelper | function | high | no references found in scope |
   | cli/index.py:1 | main | function | low | entry-point file — verify manually |

   N high-confidence candidates, M low-confidence. Advisory only — nothing removed yet.
   ```

   If zero candidates found, say so — that's a real (clean) result, not a no-op.

## Confirm-then-remove loop

After the report:

1. Ask the user which candidates (if any) to remove — accept a batch selection, not just one at
   a time.
2. For each confirmed candidate, remove the declaration (and now-orphaned code it alone made
   reachable, if obviously scoped to it) with a normal edit.
3. The removal becomes part of whatever sprint is active. It is graded by that sprint's own
   acceptance criteria and gates — this skill does not run its own separate close process.
4. If no sprint is active when removal is confirmed, say so and suggest `sprint start` before
   editing — don't edit outside an active sprint's diff.

## Gotchas

- **Dynamic dispatch and reflection** (`getattr(obj, name)`, `eval`, string-keyed routing
  tables) call a symbol by name at runtime — grep finds zero static references even though the
  symbol is live. Treat any candidate near a router/registry/dispatch table with suspicion; ask
  before removing.
- **String-only references** — a symbol name mentioned only in docs, a skill's own prose, a YAML
  config, or a CI workflow file counts as a reference for this heuristic's purposes (the grep
  pattern is name-based, not import-graph-based) but can still hide a real caller `grep -w`
  missed due to word-boundary quirks (e.g. template-literal interpolation). Spot-check a sample
  of "zero reference" results before trusting the count at scale.
- **Barrel/re-export files** (`export * from './foo'`) make a symbol look referenced by the
  barrel file itself even when nothing imports it *from* the barrel — this heuristic will
  under-report in that case, not over-report; treat "zero candidates" from a heavily-barrelled
  codebase with caution.
- **Test-only fixtures** (helpers used only inside `*.test.*`/`*_test.*` files) will show a
  reference and won't be flagged — correct behavior, since the code is still reachable from the
  test suite, but worth knowing if the goal is trimming test-only cruft too (out of scope here).
- **CLI entry points invoked only by name** from `package.json` `bin`/`scripts`, a shebang, or a
  Makefile are real usages grep won't see as a symbol reference — this is exactly what the
  low-confidence entry-point classification exists to catch; don't loosen that filter.
- **Go `Test*` functions are called by the test runner via naming convention, not by any textual
  reference** — `func TestFoo(t *testing.T)` matches the exported-func pattern (uppercase start)
  and will show zero other references, since nothing ever calls it by name in source. Live-checked
  against canon's own `tools/cockpit-daemon/main_test.go`: `TestPreviewRootFor` has exactly one
  match repo-wide — its own declaration. Always exclude `^func Test[A-Z]` (and `^func Benchmark[A-Z]`
  / `^func Example[A-Z]`) from Go candidates before counting references, rather than relying on
  the entry-point low-confidence filter to catch them — they aren't entry-point files, they're a
  distinct convention-dispatched class.
