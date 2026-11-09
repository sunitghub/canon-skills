---
gate: guard
kind: recorded
miss: security-review ran in wrapup before the advisory reviewer, so a reviewer fix that touched an input boundary never got a security pass
source: t-52a1
expect: security-review runs after the reviewer and its fixes, on the final diff, before the evaluator; tests/sprint-checklists.sh pins the order
---
