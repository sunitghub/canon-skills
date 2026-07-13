# Summary

| Acceptance item | Status | Notes |
|---|---|---|
| Card-level button, visible only on ci:true cards | delivered | `app.html`'s `.ci-run-btn`, next to `ciBadge()` |
| Modal panel with base-ref input, client-side non-empty guard | delivered | `#m-headless-baseref`/`#m-headless-run` |
| Trigger starts background run, UI polls with elapsed time | delivered | `POST`/`GET .../headless-run`, 3s poll interval |
| Double-spawn guard | delivered | verified via a real spawn-count marker file, not just response shape |
| PASS/FAIL verdict + output view; report files auto-appear as doc tabs | delivered | no custom viewer needed — `t-1bea` already made this free |
| Python/Go parity | delivered | `tests/sprint-check-api-parity.sh` new fixture, real state assertions |
| Sibling-path invocation, never `$PATH` | delivered | mirrors `resolveAppHTML`'s existing pattern in Go |
| Never writes ticket.md / changes status | delivered | confirmed via grep by both reviewer and evaluator |
| Auth/rate-limit failure surfaces real error text | delivered | dedicated Playwright test, exact stderr text asserted |

Added a "Run headless grading" trigger to the sprint-check board — a new `POST`/`GET /api/ticket/<id>/headless-run` endpoint pair in both `server.py` and `main.go`, an in-memory run-state store, and a modal panel with base-ref input, polling, and PASS/FAIL display. Unlike `t-978c`'s CI badge, this needed genuinely new logic in both languages (neither backend had an async-execution pattern before). Full high-risk pipeline ran: orient → grill (4 gray areas resolved with the user) → impact analysis (LOW-MEDIUM overall) → implementation → both gates on the full session model. A real deadlock bug was caught and fixed during manual testing before any automated test existed (`server.py`'s double-spawn guard called a lock-reacquiring helper from inside an already-held `threading.Lock`); `main.go`'s equivalent was explicitly re-checked and confirmed not to share the bug, rather than assumed safe by symmetry. Reviewer (fresh subagent) verdict: YES, no findings — independently re-ran the parity test to confirm the fix and injection safety. Evaluator (fresh subagent) verdict: pass, all 9 criteria and 7 test-plan items — independently re-ran both test suites (parity + full 37-test Playwright suite) and confirmed real spawn-count/elapsed-time/error-text assertions, not shape-only checks. `tools/sprint-headless` confirmed byte-identical after every test run throughout implementation and both gate dispatches. No deferred/waived items.
