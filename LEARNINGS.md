# Learnings

learnings-sweep last run: 10-22-2026 20:17

<!-- canon:learnings:BEGIN -->
| Date | Ticket | Finding | Status |
|---|---|---|---|
| 2026-10-22 | [t-fcb3](.tickets/t-fcb3/learnings.md) | A gate rule that names a pattern as a finding (CI `permissions:`/unpinned actions) collided with the same gate's "no hardening" exclusion; the reviewer caught it and a behaviour check reproduced it, so new gate rules need their condition for being a finding stated next to them. | UNPROMOTED |
| 2026-10-22 | [t-d40b](.tickets/t-d40b/learnings.md) | A check done only when data is saved does not protect a later reader of the same file, and a load-then-slow-call-then-save handler overwrites changes made meanwhile: Refresh loaded the registry, fetched for seconds, wrote it back, and would have sent an API key to whatever host a hand-edited source named; re-check at the point of use and re-load before the write. | UNPROMOTED |
| 2026-10-22 | [t-8f48](.tickets/t-8f48/learnings.md) | Under `set -e` a bare `v="$(cmd)"` with a failing cmd exits silently: `tkt worktree-reset` died with no output when `origin/HEAD` was unset, a fallback the hand-written tests never reached; mutation-sweep survivors on that line led to the test that exposed it. | UNPROMOTED |
| 2026-10-22 | [t-b525](.tickets/t-b525/learnings.md) | A self-checking guard test's summary line hardcoded its plant count ("14 planted breaks") instead of printing the counter it already kept, so adding a plant would make it lie silently; print the counter. | UNPROMOTED |
| 2026-10-22 | [t-f053](.tickets/t-f053/learnings.md) | A scratch copy made with `git archive` has no `.git`, so git/worktree tests fail identically on branch and base; use `git clone` + `git checkout` for copies that run tests. | `promoted → skills/sprint/reference/eval.md` |
| 2026-10-22 | [t-eb92](.tickets/t-eb92/learnings.md) | A lint with a per-line exemption marker is only as strong as who may write the marker: my scripted rewrite put `/* non-ticket */` on four ticket-folder deletes (`made` dirs), so the lint passed over the very hole it guards; the evaluator caught it. Give an exemption a mechanical reject (here: not on a line naming `.tickets`/`made`) and read what a marked line really deletes. | `promoted → standards/efficiency-notes.md` |
| 2026-10-21 | [t-7f5f](.tickets/t-7f5f/learnings.md) | A cloud pass under bash 5 does not cover macOS bash 3.2: PR #89's `;;&` (bash 4+) passed the cloud's tests and evaluator and died with a syntax error in `tkt merge-pr`'s Mac suite run, so a cloud-graded shell change is only as good as that run (and `tkt land` refused the already-passing head, so the fix needed a hand-made worktree: t-6623) | `promoted → standards/efficiency-notes.md` |
<!-- canon:learnings:END -->
