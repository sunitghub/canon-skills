# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-835f`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->
<!-- Optional style for behavior: When <trigger>, <system> <does response>. Example: When tkt gets an unknown id, it exits 1 and names the id. Docs and files stay free text. -->

- [ ] When pre-gate runs, its stamped line ends with a `size (advisory)` field: `planned N files, changed M, +A/-D` (N = changed files plan.md's `## Files` names, M = changed files excluding `.tickets/`).
- [ ] When a changed file is not named in plan.md's `## Files`, the field lists it as `unplanned: <path>` (up to 8, then `+K more`); a directory entry ending `/` in `## Files` names every file under it.
- [ ] When a file's net added lines (added minus removed) exceed `file-net` in `tools/size-caps.tsv`, or the diff's total exceeds `total-net`, the field says `large: <path> +N` or `total +N`; both limits live only in that table.
- [ ] When a new non-test, non-doc file is added and the diff holds no test file (`tests/`, `*_test.go`, `*.test.js`, `*.spec.js`), the field says `no test: <path>`.
- [ ] A size flag never changes the exit code, and a missing plan.md or limits table says `size: skipped | <reason>`, never a pass.
- [ ] The same numbers are in `.tickets/<id>/evidence/pre-gate.log` (the existing stamp), and `complete-checklist.md`'s Pre-gate line tells the reviewer and the summary to quote it.

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [ ] `tests/pre-gate-check.sh` (protects the pre-gate step of `sprint complete`): scratch repo with a plan naming one of three changed files, a 600-line file, a new script and no test; asserts each flag text, the planned/changed/+A/-D numbers, a directory entry, exit 0 on flags, and `skipped` with no plan.md.
- [ ] Revert-prove: with the `unplanned` branch and the `large` branch each removed in a scratch copy, the matching assertion fails.
- [ ] `shellcheck -S warning tools/pre-gate-check.sh`; `scripts/test.sh` stamp on a clean tree.

## QA
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [ ] Tested locally
