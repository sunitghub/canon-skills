# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-200b`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->

- [x] A `ci: true` ticket card shows a "Run headless grading" button next to the CI badge; non-CI cards show no such button.
- [x] Clicking it opens the ticket modal with an inline base-ref input; submitting with it empty is blocked client-side before any request is sent.
- [x] Submitting a valid base-ref starts a background `sprint-headless` run and the UI begins polling, showing elapsed time while `status: running`.
- [x] A second trigger while one is already running for that ticket does not start a second subprocess — it returns/reflects the existing run's state.
- [x] On completion, the UI shows the `HEADLESS_VERDICT` (PASS/FAIL) and surfaces a way to view the persisted output (expandable output view; `review-notes.md`/`eval-report.md` auto-appear as doc tabs once `sprint-headless` writes them per `t-1bea`, no custom viewer needed).
- [x] `server.py` and `main.go` expose the same endpoint pair (`POST`/`GET .../headless-run`) with the same response shape — verified via a parity fixture, not assumed.
- [x] `tools/sprint-headless` is invoked via a path relative to each server's own file location, never via `$PATH` or a hardcoded absolute path.
- [x] The new endpoints never write `ticket.md` or change ticket status.
- [x] A `claude -p` auth/rate-limit failure surfaces its real error text in the UI, not a silently swallowed/generic failure.

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

> All tests must pass before sprint complete is accepted.

### Functional tests
- [x] `tests/sprint-check-api-parity.sh` gains a fixture/case for the new endpoint pair, confirming Python and Go return the same response shape for `running`, `done`, and `idle` states, using a stub `sprint-headless` (no real `claude -p` call).
- [x] `tests/sprint-check-app.spec.js` gains Playwright coverage: trigger → poll → verdict display, using a stub `sprint-headless` (temporarily swapped in, backed up/restored per test).
- [x] A double-trigger test confirms no second subprocess spawns while one is already running (verified via a run-marker file written by the stub, not just response shape).
- [x] `npm run test:ui` (Playwright, 37/37) and `npm test` (bash suite, includes both Go and Python parity) all pass.

### Impact tests
- [x] (Blast radius, MEDIUM) A slow (8s) stub still shows increasing elapsed time across two poll cycles in the UI, not a static/frozen "Running…" — proves the pre-mortem's stuck-run visibility requirement, not just the happy path.
- [x] Confirm a `claude -p`-failure-style stub (mirroring `tests/sprint-headless.sh`'s existing invocation-error message text) surfaces its real error text through the poll endpoint to the UI, not a generic failure.

### Regression tests
- [x] Full `npm test` and `npm run test:ui` pass with no regression to `t-978c`'s CI badge or any other existing sprint-check-app/go coverage (37/37 Playwright, full bash suite including Go's own tests).

**Test location:** `tests/sprint-check-api-parity.sh`, `tests/sprint-check-app.spec.js`, `tools/sprint-check-go` (Go's own test suite, run via `npm test`).

## QA
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [x] Tested locally — manually live-tested both backends' endpoints end to end with curl before writing automated tests (including catching and fixing a real deadlock bug in `server.py`'s double-spawn guard: `threading.Lock` isn't reentrant, and the original code called `get_headless_run_state()` from inside an already-held lock). Manually verified the UI (button, panel, trigger, poll, PASS/FAIL, output view) via an interactive Playwright script and screenshots before writing permanent test coverage. All scratch servers/stubs/tickets cleaned up; `tools/sprint-headless` confirmed restored to its real content after every test run (`git status --porcelain` checked clean each time).

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| code-simplifier | ran | reviewed the new endpoint/state-store code in both languages in-context — no simplification opportunity, deadlock-avoidance comments are load-bearing (not decorative) |
| code-reviewer | ran | reviewed the 5-file diff against the 8-dimension checklist — no findings, matches fresh reviewer's independent YES |
| reviewer | ran | verdict: YES (model: claude-sonnet-5) — independently re-ran the parity test and confirmed the deadlock fix, injection safety (argv-list execution, no shell), and Python/Go parity |
| security-review | ran | new API endpoints reaching a subprocess call — traced `base_ref` (POST body, external input) into `subprocess.Popen`/`exec.Command`: both use argument lists, never a shell string, so no injection vector regardless of validation; server-side regex validation (`^[A-Za-z0-9._/-]+$`) matches `sprint-headless`'s own internal check, genuine defense in depth. `_host_ok`/Origin-header checks (pre-existing) still gate both new routes. No secrets/credentials touched; `ANTHROPIC_API_KEY` handling unchanged (inherited from the server process's own environment, never passed through the new endpoint). No HIGH/MEDIUM findings. |
| repo-check | ran | tools/, tests/ changed; `bash -n`/`py_compile`/`go vet`/`gofmt -l` all clean; `tests/doc-mirror-parity.sh` unaffected (review.md/eval.md untouched) |
| doc-audit | skipped | no README/guides/docs/tools/*.md content changed |
| eval | ran | verdict: pass — eval-report.md written (model: claude-sonnet-5); independently re-ran both test suites and confirmed real spawn-count/elapsed-time/error-text assertions, not shape-only checks |
