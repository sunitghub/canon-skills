---
gate: guard
kind: recorded
miss: sprint eval-verdict run in a worktree that holds its own .tickets/ copy reads that copy: a stale failing eval-report there counted a failure (eval_fail_count 1) while main held the real passing report
source: t-6be7
expect: eval-verdict says the worktree copy and main hold different eval-reports, or reads the report the evaluator just wrote, and does not count the stale one
---
