---
gate: evaluator
kind: replay
miss: the evaluator failed round 1 (criterion 8 partial) and found that a newline in a file name splits the find loop, so a user's cwd file is deleted (tools/skills/project.sh:357); fixed in bd0eef26
source: t-38ab
ticket: t-38ab
ref: feee0465
base: 78c0f6eb
fix: bd0eef26
catch: newline|-print0|read -r -d
---
