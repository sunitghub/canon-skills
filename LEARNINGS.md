# Learnings

learnings-sweep last run: 10-22-2026 02:25

<!-- canon:learnings:BEGIN -->
| Date | Ticket | Finding | Status |
|---|---|---|---|
| 2026-10-22 | [t-eb92](.tickets/t-eb92/learnings.md) | A lint with a per-line exemption marker is only as strong as who may write the marker: my scripted rewrite put `/* non-ticket */` on four ticket-folder deletes (`made` dirs), so the lint passed over the very hole it guards; the evaluator caught it. Give an exemption a mechanical reject (here: not on a line naming `.tickets`/`made`) and read what a marked line really deletes. | UNPROMOTED |
| 2026-10-21 | [t-7f5f](.tickets/t-7f5f/learnings.md) | A cloud pass under bash 5 does not cover macOS bash 3.2: PR #89's `;;&` (bash 4+) passed the cloud's tests and evaluator and died with a syntax error in `tkt merge-pr`'s Mac suite run, so a cloud-graded shell change is only as good as that run (and `tkt land` refused the already-passing head, so the fix needed a hand-made worktree: t-6623) | UNPROMOTED |
<!-- canon:learnings:END -->
