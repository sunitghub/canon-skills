---
gate: guard
kind: run
miss: sprint eval-verdict run in a worktree that holds its own .tickets/ copy reads that copy: a stale failing eval-report there counted a failure (eval_fail_count 1) while main held the real passing report
source: t-6be7
cmd: cd wt && bash "$CANON_ROOT/tools/sprint" eval-verdict t-abcd
expect_exit: 0
expect_text: eval-report.md differs between this worktree
---
