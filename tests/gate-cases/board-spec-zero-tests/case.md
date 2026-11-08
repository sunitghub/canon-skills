---
gate: guard
kind: run
miss: the board spec reported 0 tests and no failure when a worktree had no node_modules, so nothing ran and the run looked green
source: t-fb37
cmd: node "$CANON_ROOT/tests/board-spec-guard.js" --partial board-spec-chromium-run1.json
expect_exit: 1
expect_text: reported 0 tests, so nothing ran
---
