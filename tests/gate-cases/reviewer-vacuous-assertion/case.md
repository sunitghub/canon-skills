---
gate: reviewer
kind: recorded
miss: t-2178 (twice) and t-2178's evaluator failures: a test asserted a UI or output state that was already true before the change (a 'hidden' check made before the data loaded, a failed-request assertion on a fresh page), so it passed with the fix reverted and the reviewer's five old concerns had no place to name it
source: t-0ca2
expect: Guards that cannot fail: <file:line> — the assertion passes with the fix reverted (state true before the change; wait for the loaded state first) [severity: high · confidence: high]; Act On
---
