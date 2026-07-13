evaluator-run-id: 1783907168-10529

# Eval Report

Ticket: `t-200b`
Evaluated: 2026-07-12
Model: claude-sonnet-5

## Criteria

| Criterion | Status | Evidence |
|---|---|---|
| CI cards show "Run headless grading" button, non-CI cards don't | pass | `tools/sprint-check-app/app.html:2370 — \`${String(t.ci) === 'true' ? \`<button class="ci-run-btn" data-id="${esc(t.id)}" title="Run headless grading (opens ticket)">▶ Run</button>\` : ''}\`` |
| Clicking opens modal with inline base-ref input; empty submit blocked client-side | pass | `tools/sprint-check-app/app.html:2495 — \`if (!baseRef) { input.focus(); return; }\`` |
| Valid base-ref starts background run; UI polls showing elapsed time while running | pass | `tools/sprint-check-app/app.html:2491 — \`el.innerHTML = \`<span class="headless-running">Running… (${Math.round(data.elapsed || 0)}s)</span>\`\`` and verified dynamically via re-run of Playwright test (see Test Plan) |
| Second trigger while one running does not spawn a second subprocess | pass | `tools/sprint-check-app/server.py:527 — \`if existing and existing.get('status') == 'running': already_running = True\`` and Go equivalent `tools/sprint-check-go/main.go:1006`; genuinely tested via marker-file test (see Test Plan) |
| On completion shows HEADLESS_VERDICT PASS/FAIL and a way to view persisted output | pass | `tools/sprint-check-app/app.html:2489 — \`const pass = /^HEADLESS_VERDICT: PASS$/m.test(data.output || '');\`` plus `.headless-view-output` click-to-expand `<pre class="headless-output">` |
| server.py and main.go expose same endpoint pair with same response shape, verified via parity fixture | pass | `tests/sprint-check-api-parity.sh:255-303` — new section triggers, polls, and diffs `status`/`output`/`exit_code` for both servers using a real stub, not just route existence (see Test Plan detail) |
| tools/sprint-headless invoked via path relative to each server's own file location | pass | `tools/sprint-check-app/server.py:510 — \`SPRINT_HEADLESS = Path(__file__).resolve().parent.parent / 'sprint-headless'\`` and `tools/sprint-check-go/main.go:968-980 — \`resolveSprintHeadless\`` (uses `toolsDir`/`root`/cwd candidates, never `$PATH`) |
| New endpoints never write ticket.md or change ticket status | pass | grep across `start_headless_run`/`_run_headless`/`get_headless_run_state` (server.py) and `runHeadless`/`startHeadlessRun`/`getHeadlessRunState` (main.go) for `write_ticket`/`ticket.md`/`writeTicket` returns no matches |
| `claude -p` auth/rate-limit failure surfaces real error text, not generic failure | pass | `tools/sprint-check-app/server.py:534-536 — \`stdout, stderr = subprocess.PIPE, subprocess.STDOUT\`` captures combined output into `state['output']`; Go's `exec.Command(...).CombinedOutput()` at `main.go:987` does the same; verified end-to-end via re-run of the auth-failure Playwright test (see Test Plan) which asserts the exact stub stderr text `claude -p invocation failed` reaches `.headless-output` |

## Test Plan

| Item | Status | Notes |
|---|---|---|
| `tests/sprint-check-api-parity.sh` gains fixture for new endpoint pair covering running/done/idle for both backends | pass | Re-ran `bash tests/sprint-check-api-parity.sh` directly — exits 0, output confirms `headless-run idle/running/done states match`. Section at lines 251-303 asserts `status`, `output` (contains `HEADLESS_VERDICT: PASS`), and `exit_code` for both py and go, using a real stub swapped into `tools/sprint-headless` and restored via trap-bound cleanup. |
| `tests/sprint-check-app.spec.js` gains Playwright coverage: trigger → poll → verdict display, using a stub | pass | Re-ran `npx playwright test tests/sprint-check-app.spec.js -g "headless grading trigger"` against a live server on port 8423 — 4/4 passed. Stub install/restore pattern at `tests/sprint-check-app.spec.js:1620-1624` (`installStub`/returned restore fn), called in a `finally` block per test. |
| Double-trigger test confirms no second subprocess spawns, via run-marker file written by the stub | pass | `tests/sprint-check-app.spec.js:1711-1748` — stub appends `$$-$(date +%s%N)` to a `run-markers.txt` file on each real spawn; test fires two POSTs, waits for the run to finish, and asserts `markers.length === 1`. This is a genuine spawn-count check, not just response-shape inspection. Re-run confirmed pass. |
| `npm run test:ui` (37/37) and `npm test` all pass | pass | Re-ran both directly. `npm test` (full bash suite incl. Go's own `go test`) — "All tests passed." `npx playwright test tests/sprint-check-app.spec.js` — "37 passed (1.1m)". |
| (Impact/blast-radius) Slow (8s) stub shows increasing elapsed time across two poll cycles, not frozen | pass | `tests/sprint-check-app.spec.js:1685-1709` — captures `#m-headless-status` text, waits 3.5s (> one 3s poll interval), re-captures, asserts `laterText !== firstText` and still contains `Running`. Re-run individually — passed. This is a real elapsed-value diff assertion, not a static existence check. |
| Confirm `claude -p`-failure-style stub surfaces real error text through poll endpoint to UI | pass | `tests/sprint-check-app.spec.js:1660-1683` — stub writes `Error: claude -p invocation failed (exit 1). Hard-failing.` to stderr and exits 1; test asserts `.headless-output` contains `claude -p invocation failed` after clicking view-output. Re-run individually — passed. Both backends capture combined stdout+stderr so this text is not swallowed. |
| Full `npm test` and `npm run test:ui` pass with no regression to t-978c's CI badge or existing coverage | pass | Re-ran full suites as above; all 37 Playwright tests and full bash suite (including `tools/sprint-check-go`'s `go test`) passed with no failures. |

## Findings

No findings.

## Verdict

pass: All nine acceptance criteria and seven test-plan items are backed by concrete, re-verified evidence — the parity fixture and Playwright suite were re-run directly (not just read) and confirm real spawn-count, elapsed-time, and error-text-surfacing behavior rather than shape-only assertions; `tools/sprint-headless` was confirmed byte-identical (`git status --porcelain` clean) after all test runs, and no ticket.md writes exist in any new code path.
