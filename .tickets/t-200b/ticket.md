---
id: t-200b
status: closed
created: 2026-07-12T23:39:11Z
type: task
priority: 3
eval_override: false
ci: true
---
# Trigger sprint-headless grading from sprint-check UI

Let a user run 'sprint-headless <id> --base-ref <ref>' from the sprint-check board instead of only the CLI -- a button/action on a CI-eligible ticket's card or detail view that shells out to the script and surfaces its output (PASS/FAIL verdict, findings) in the UI. Needs design work before implementation: server.py currently has no long-running-process execution model (existing endpoints are fast, synchronous ticket-status/read operations) -- running sprint-headless can take real wall-clock time (multiple claude -p subagent dispatches), so this needs either polling (kick off + GET status) or streaming (SSE/websocket) rather than a blocking POST. Also needs a base-ref input (free text? a dropdown of recent commits/tags?) and must not silently swallow the ANTHROPIC_API_KEY/auth requirement. This is the same manual step currently documented as step 5 in examples/restaurant-bill-split/README.md's Session-2 section and mirrored in t-f693's GitHub Actions variant -- a UI trigger would remove that CLI step for students without removing the CLI path itself (tkt ci and the CLI invocation should remain available, same 'intentional manual step, not hidden by UI convenience' principle as the CI badge ticket). Depends on t-978c (CI badge) landing first for a consistent card surface to attach the action to; also depends on/benefits from t-1bea (sprint-headless report persistence) so the UI has a real file to read from rather than parsing raw stdout itself.
