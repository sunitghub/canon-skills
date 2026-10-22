# Learnings

learnings-sweep last run: 10-22-2026 05:07

<!-- canon:learnings:BEGIN -->
| Date | Ticket | Finding | Status |
|---|---|---|---|
| 2026-10-22 | [t-f053](.tickets/t-f053/learnings.md) | A scratch copy made with `git archive` has no `.git`, so git/worktree tests fail identically on branch and base; use `git clone` + `git checkout` for copies that run tests. | `promoted → skills/sprint/reference/eval.md` |
| 2026-10-22 | [t-eb92](.tickets/t-eb92/learnings.md) | A lint with a per-line exemption marker is only as strong as who may write the marker: my scripted rewrite put `/* non-ticket */` on four ticket-folder deletes (`made` dirs), so the lint passed over the very hole it guards; the evaluator caught it. Give an exemption a mechanical reject (here: not on a line naming `.tickets`/`made`) and read what a marked line really deletes. | `promoted → standards/efficiency-notes.md` |
| 2026-10-21 | [t-7f5f](.tickets/t-7f5f/learnings.md) | A cloud pass under bash 5 does not cover macOS bash 3.2: PR #89's `;;&` (bash 4+) passed the cloud's tests and evaluator and died with a syntax error in `tkt merge-pr`'s Mac suite run, so a cloud-graded shell change is only as good as that run (and `tkt land` refused the already-passing head, so the fix needed a hand-made worktree: t-6623) | `promoted → standards/efficiency-notes.md` |
<!-- canon:learnings:END -->
