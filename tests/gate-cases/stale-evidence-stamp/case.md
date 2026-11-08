---
gate: guard
kind: run
miss: an evidence stamp taken at an older commit would be read as the proof for the graded head
source: t-e3cd
cmd: cd repo && bash "$CANON_ROOT/tools/sprint" check-evidence t-abcd
expect_exit: 1
expect_text: REFUSE  stale suite.log
---
