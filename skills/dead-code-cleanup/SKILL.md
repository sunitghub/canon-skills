---
name: dead-code-cleanup
description: Scans a repo for likely-unreferenced top-level symbols (JS/TS exports, Python def/class, Go func, Bash functions), reports dead, test-only and over-exported ones as candidates, and writes a structured `dead-code-report.md` (summary + candidate tables, including languages it skipped). Use when asked to find dead code, unused exports, or unreferenced functions, or to clean up a codebase. Advisory-first — never deletes without explicit confirmation.
category: dev
tags: [cleanup, code-quality, dead-code, verification]
---

# Dead Code Cleanup

Finds code that nothing calls and reports it — it does not delete anything on its own. The scan
edits no existing file; it writes a structured `dead-code-report.md` (confirm-first) and, only on
per-candidate confirmation, removes code as a normal gated edit.
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

**Run the scanner first.** Steps 1–3 are implemented by canon's `dead-code-scan.sh` (Bash, git and
awk only, so it runs in Git Bash on Windows): `bash ~/.canon/tools/dead-code-scan.sh [<path>...]`
(in the canon repo itself, `bash tools/dead-code-scan.sh`). It prints one tab-separated row per
candidate — `class  file:line  symbol  lang  entry  refs`, class `DEAD`/`TESTONLY`/`OVEREXP` — then
`# scanned:`, `# skipped:` and `# checked:` lines; it exits 2 outside a git repo. It reads tracked
files only (commit or `git add` new code first). Copy `# scanned:` and `# skipped:` into the
Summary's `Languages scanned`/`Languages skipped` rows as printed — a language with no candidates
was still scanned. Its rows are the
candidate list: report **every** row, never a sample, and do not re-derive them by hand — a model
checking hundreds of symbols one grep at a time skips most of them. Your part is the judgment the
script cannot make: the entry points and dynamic dispatch in step 3 and the Gotchas. Only if the
script is missing, follow steps 1–3 by hand and say in the report that the scan was manual and may
be incomplete.

1. **Extract candidate declarations.** Grep-based, one pattern set per language present in
   scope:
   - JS/TS (`.js`, `.ts`, `.jsx`, `.tsx`): `export [async] (function|const|class) <Name>` (an *export*)
   - Python (`.py`): top-level `def <name>` / `class <Name>` not prefixed with `_`
   - Go (`.go`): top-level `func <Name>(` — exported (uppercase start, an *export*) and unexported
     (lowercase start) alike. Exclude `main`, `init`, and `Test*`/`Benchmark*`/`Example*`
     (runtime/test-runner convention, not a static reference — see Gotchas). Methods
     (`func (r T) Name(`) are not candidates: interface satisfaction calls them without a name.
   - Bash (`.sh`, `.bash`, and extensionless files whose first line is a `sh`/`bash` shebang, e.g.
     `#!/usr/bin/env bash`): top-level `<name>() {` or `function <name>` declarations

   Skip any language not in this list — do not guess a pattern for an unfamiliar language. But
   never skip silently: count the files in scope with one of these common source extensions —
   `.cs .rs .java .kt .rb .php .swift .c .h .cpp .scala .lua .ps1` — and report each extension
   found, with its file count, under `Languages skipped` (step 4). Data and doc files (`.md`,
   `.json`, `.yml`, …) are not source and are never listed.

2. **Count code references.** For each candidate symbol, `grep -rnw` the symbol across the scope,
   excluding the declaration's own line. Only a **code reference** counts. Drop a match when:
   - it is in a doc file: `*.md`, `*.txt`, `CHANGELOG*`, or anything under `.tickets/` or
     `.reports/` (mentions in prose, tickets, changelogs and earlier reports never keep code alive);
   - its line is comment-only — its first non-space characters are `#`, `//`, `/*` or `*` (a
     shebang line counts as a comment).

   Then sort the remaining code references by where they are:
   - **test** — in a test file: anything under `tests/`, `test/` or `__tests__/`, or named
     `*.test.*`, `*.spec.*`, `*_test.go`, `test_*.py` or `*_test.py`;
   - **own file** — in the declaring file itself;
   - **other** — any other non-test file.

3. **Classify.** Each candidate lands in at most one class:
   - **Dead** — no code reference at all.
   - **Test-only** — code references exist, but only in test files (the production code is
     reachable only from its tests).
   - **Over-exported** — an *export* (JS/TS export or exported Go func) whose only code references
     are in its own file — no other file and no test uses it: live code, but the export (or Go
     capital letter) is unneeded. A test that imports the export needs it, so that is live.
   - Otherwise live — not reported. For a non-export (Python, unexported Go, Bash), a call in its
     own file is a normal use and makes it live.

   A candidate declared **in a test file** can only be Dead: a test helper used by tests is live,
   never Test-only or Over-exported.

   Then set confidence on Dead rows (a Test-only or Over-exported row in an entry-point file
   just says so in its Reason):
   - **High** — the declaring file is not an entry-point pattern.
   - **Low** — the declaring file matches an entry-point pattern:
     `index.*`, `__init__.py`, `main.go`, `cli.*`, or any file a `package.json`/shebang/build
     config names directly. These are likely public API surface or process entry points invoked
     by name from outside grep's reach — flag them, don't bury them, but don't recommend removal.
     **Exception — Bash functions and unexported Go funcs never take the downgrade:** a Bash
     function can only be called from its own script or a file that `source`s it, and an unexported
     Go func only from its own package; grep sees all of those, so they stay High. The scanner's
     `entry` column applies the filename and shebang patterns and this exception; check the
     `package.json`/build-config case yourself.

4. **Report.** The scan itself edits no file. Print the Summary inline, then — **confirm-first**,
   mirroring `context-check`/`context-doctor` — write a structured `dead-code-report.md` at the
   repo root: ask `Write dead-code-report.md to the repo root? (y to confirm)`, overwrite if present
   (a point-in-time snapshot, not a log). Structure:

   ```markdown
   # Dead Code Report

   _Scope: <path> · Generated: <ISO date>_

   ## Summary

   | Metric | Count |
   |---|---|
   | High-confidence dead | N |
   | Low-confidence dead (entry-point) | M |
   | Test-only callers | T |
   | Over-exported | O |
   | Languages scanned | js, py, go, sh |
   | Languages skipped | .rs (12 files), .cs (3 files) — or `none` |

   > Advisory only — nothing removed. Confirm candidates to remove; removals go through the sprint's gates.

   ## High-confidence candidates

   | File:line | Symbol | Kind | Reason |
   |---|---|---|---|
   | src/foo.js:12 | oldHelper | function | no code references in scope |

   ## Low-confidence — verify manually

   | File:line | Symbol | Kind | Reason |
   |---|---|---|---|
   | cli/index.py:1 | main | function | entry-point file — likely invoked by name |

   ## Test-only callers

   | File:line | Symbol | Kind | Reason |
   |---|---|---|---|
   | src/fmt.py:40 | legacy_format | function | called only from tests/test_fmt.py |

   ## Over-exported

   | File:line | Symbol | Kind | Reason |
   |---|---|---|---|
   | src/view.js:29 | rowFor | function | exported, used only in its own file — drop the export |

   ## Caveats

   - Dynamic dispatch/reflection, barrel re-exports, string-only references, CLI entry points, and
     test-runner conventions can hide real callers — spot-check before removing (see Gotchas).
   - Languages skipped were not scanned at all: zero candidates says nothing about them.
   ```

   Render `None.` under a candidate section with no rows. If **all** tables are empty, still write
   the report (all `None.`) and say so — a clean result, not a no-op — and name any languages
   skipped in that sentence, so a clean result never hides an unscanned codebase. The `Kind` column is the
   declaration type (`function`/`class`/…); confidence is expressed by which table a row lands in.

## Confirm-then-remove loop

After the report:

1. Ask the user which candidates (if any) to remove — accept a batch selection, not just one at
   a time. **Before applying any removal, surface the working-tree state** — check
   `git status --porcelain`; if there are uncommitted changes, tell the user the removals will be
   added to their current diff and offer **commit-first / proceed-anyway / cancel**. This is an
   *informed confirmation, not a hard clean-tree gate*: git makes every removal revertible
   per-file (`git restore <file>`) whether or not the tree was clean, so never block on a dirty
   tree — just make the undo choice visible (t-2201). A clean tree only buys a tidier isolated
   diff, which the user may or may not want.
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
- **String-only references** — a mention in docs, tickets, CHANGELOG, earlier reports or a
  comment is dropped (step 2): it never keeps code alive. A mention in a YAML config or CI
  workflow still counts — it may be a real call (`run: tools/foo.sh`). The pattern is name-based,
  not import-graph-based, so `grep -w` can also miss a real caller to word-boundary quirks (e.g.
  template-literal interpolation, a Bash function name containing `-`). Spot-check a sample of
  Dead results before trusting the count at scale.
- **Bash string-built calls** — `"cmd_$sub"` or `$handler "$@"` calls a function whose name grep
  never sees whole. A static `case` dispatch (`start) cmd_start "$@" ;;`) is a normal reference.
  Before reporting a Bash function Dead, check its file for a variable used as a command name; if
  one exists and the function's name fits the prefix, move it to Low-confidence.
- **Barrel/re-export files** (`export * from './foo'`) make a symbol look referenced by the
  barrel file itself even when nothing imports it *from* the barrel — this heuristic will
  under-report in that case, not over-report; treat "zero candidates" from a heavily-barrelled
  codebase with caution.
- **Test-only callers** — production code reachable only from its tests is its own class, not
  live: the tests keep it compiling, nothing ships through it. Remove the code and its tests
  together, or keep it if the test pins a contract a future caller needs. Helpers declared inside
  test files are not reported unless Dead (step 3).
- **CLI entry points invoked only by name** from `package.json` `bin`/`scripts`, a shebang, or a
  Makefile are real usages grep won't see as a symbol reference — this is exactly what the
  low-confidence entry-point classification exists to catch; don't loosen that filter.
- **Go `Test*` functions are called by the test runner via naming convention, not by any textual
  reference** — `func TestFoo(t *testing.T)` matches the exported-func pattern (uppercase start)
  and will show zero other references, since nothing ever calls it by name in source. Live-checked
  against canon's own `tools/canon-go/internal/daemon/main_test.go`: `TestPreviewRootFor` has exactly one
  match repo-wide — its own declaration. Always exclude `^func Test[A-Z]` (and `^func Benchmark[A-Z]`
  / `^func Example[A-Z]`) from Go candidates before counting references, rather than relying on
  the entry-point low-confidence filter to catch them — they aren't entry-point files, they're a
  distinct convention-dispatched class.
