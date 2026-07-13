# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-200b`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->
<!-- Optional, append: | Gate model: <value> -- forces the sprint-close reviewer/evaluator onto that model, overriding the automatic low-risk downgrade. Valid values (case-insensitive): a model id (e.g. haiku, sonnet, opus), or the literal "session" to force full session-model review. Omit entirely for automatic behavior -- there is no separate "auto" value; absence already means automatic. -->

Tier: high-risk | Risk: overall LOW-MEDIUM — new API endpoint pair reaching a subprocess, but argv-list execution closes off shell injection; main risk is UX honesty on a slow/stuck run, mitigated by elapsed-time polling and a dedicated test.

- [x] Plan approved — proceed to implementation

## Grill

1. **Dual-backend scope** — resolved: implement both Python and Go in this pass, matching `t-978c`'s Windows-parity precedent.
2. **Trigger placement** — resolved: card-level button next to the CI badge (`t-978c`), visible only on `ci: true` cards.
3. **Base-ref input** — resolved: free text field; `sprint-headless`'s own regex validation surfaces a clear error on bad input.
4. **Progress surfacing** — resolved: polling, matching every existing endpoint's synchronous request/response shape — no new transport pattern in either backend.
5. **Server-restart during a run** — resolved (self-resolved, no genuine tradeoff worth a question): accept as a documented limitation. The underlying `sprint-headless` subprocess is a child of the server process and dies with it either way — a restart already loses the run for real, not just in the UI's bookkeeping. Building persistence to survive a restart would be solving a problem that doesn't actually exist (there's nothing to "recover," the process is gone); document it, don't engineer around it.

## Pre-mortem

What would have to be true for this to go badly, ranked by likelihood:
1. **Python and Go diverge in run-state shape or polling response format**, since this is genuinely new logic in both, not a generic pass-through like `t-978c`. Mitigated by extending `tests/sprint-check-api-parity.sh`'s existing pattern to cover the new endpoints, same as every prior dual-backend ticket.
2. **A student triggers a run, navigates away, and the board loses track of it** (in-memory-only state, no ticket/card indicator of "already running"). Mitigated by having the poll endpoint reflect state keyed by ticket ID regardless of which client asks — reopening/refreshing the board still finds the same in-progress run, not just the browser tab that started it.
3. **The subprocess never terminates** (a genuine `claude -p` hang) and ties up the background thread/goroutine indefinitely. `sprint-headless` itself has no internal timeout today — this ticket doesn't need to add one either (out of scope; the CLI would have the identical exposure if a student just ran it directly), but the polling UI must not spin forever silently — surface elapsed time so a stuck run is visible, not just invisible.
4. **The free-text base-ref field lets a student submit blank/garbage input repeatedly**, generating avoidable failed runs. Mitigated by client-side non-empty validation before the POST, on top of the server's existing regex — cheap, doesn't block anything legitimate.

## Impact Assessment

| Dimension | Rating | Reason |
|---|---|---|
| Audience | LOW | Local-only tool (127.0.0.1-bound), affects only the requesting user's own board session. |
| Reversibility | LOW | Triggering a grading run has no persistent side effect beyond the report files `t-1bea` already made safe to write (fail-open, git-trackable, easily reverted). |
| Blast radius | MEDIUM | A hung/misbehaving background process ties up a server thread/goroutine; contained to that one server process, not shared state, but real enough to need the pre-mortem's elapsed-time visibility rather than a silent spinner. |
| Trigger paths | LOW | One new endpoint pair (trigger + poll) per backend, single button in the UI — no duplicate bindings. |
| Cascade risk | LOW | Output is the same `review-notes.md`/`eval-report.md` files `t-1bea` already made the durable record for — no new downstream consumer beyond what already reads those files. |

**Overall: LOW-MEDIUM** — no HIGH dimension; the one MEDIUM (blast radius) is about UX honesty during a long-running/stuck call, not data safety or shared-state risk.

### Required actions
- None mechanically required (no HIGH dimension). Added anyway per the pre-mortem: a test proving a hung/slow subprocess still shows visible elapsed-time progress rather than an indefinite silent wait.

### Open questions
- None remaining — grill resolved all identified gray areas.

### Human checkpoint
- Required: yes — new API endpoint pair reaching a subprocess call, in scope of `SKILL.md`'s security-sensitive trigger list ("API endpoints"), even though the actual injection risk is structurally closed off (argv-list `subprocess`/`exec.Command`, never a shell string).
- Decision needed: approve the grill resolutions above (dual-backend scope, placement, input UX, polling, restart handling).
- Human resolution: approved — grill answers given directly by the user.
- Approved autonomy: implement + run tests.

## Approach

1. **`tools/sprint-check-app/server.py`**: add an in-memory `_HEADLESS_RUNS: dict[str, dict]` (guarded by a `threading.Lock`), keyed by ticket ID. `POST /api/ticket/<id>/headless-run` (body: `{"base_ref": "<ref>"}`) — validate `id` against `t-[a-z0-9]{4}` and `base_ref` against `sprint-headless`'s own safe-ref shape server-side (defense in depth, not the sole guard); if a run is already `"running"` for that ID, return its current state instead of starting a second one (no double-spawn); otherwise spawn `subprocess.Popen([str(SCRIPT_DIR.parent / 'sprint-headless'), id, '--base-ref', base_ref], stdout=PIPE, stderr=STDOUT, text=True)` in a background thread that records start time, waits for completion, and stores `{"status": "running"|"done", "output": <text>, "exit_code": <int|None>, "started_at": <ts>}`. `GET /api/ticket/<id>/headless-run` returns current state (or `{"status": "idle"}` if none ever ran) — includes elapsed seconds while running, so the UI can show honest progress instead of a silent spinner (pre-mortem #3).
2. **`tools/sprint-check-go/main.go`**: same endpoint pair, same state shape, `exec.Command` equivalent, a package-level map guarded by `sync.Mutex`, a goroutine per run instead of a thread.
3. **`app.html`**: a "Run headless grading" button next to the CI badge on `ci: true` cards (only shown for CI-eligible tickets, matching the badge's own visibility rule); clicking opens a small inline free-text base-ref field with a non-empty check before enabling submit; on submit, POST to start, then poll `GET .../headless-run` every few seconds, rendering status/elapsed time/verdict; on completion, surface PASS/FAIL and a way to view the persisted `review-notes.md`/`eval-report.md` (reuse the existing doc-tab viewer already in the ticket modal, since `t-1bea` guarantees those files exist on completion when extraction succeeds).
4. **Tests**: extend `tests/sprint-check-api-parity.sh` for the new endpoint pair's response shape; add Playwright coverage in `tests/sprint-check-app.spec.js` for trigger→poll→verdict-display, using a stub `sprint-headless` (same stub-on-PATH-equivalent pattern as `tests/sprint-headless.sh`, adapted to a fixed sibling-path invocation) so the test suite never makes a real `claude -p` call.

## Files
- `tools/sprint-check-app/server.py` — new endpoint pair, in-memory run-state store, background thread.
- `tools/sprint-check-go/main.go` — same, Go equivalent.
- `tools/sprint-check-app/app.html` — trigger button, base-ref input, polling UI, verdict display.
- `tests/sprint-check-api-parity.sh` — new endpoint parity fixture.
- `tests/sprint-check-app.spec.js` — trigger→poll→verdict Playwright coverage.

## Decisions
- Referencing `sprint-headless` via a path relative to each server's own file location (not `$PATH`) — sidesteps the whole PATH-resolution problem class from `t-9737`/`t-d351`/`t-af61` entirely, since the server process's own location is always known regardless of the invoking user's shell setup.
- No new timeout added to the subprocess call itself — `sprint-headless`/`claude -p` have no internal timeout today, and adding one here would be solving a problem the CLI itself already has, out of this ticket's scope. The UI's elapsed-time display makes a stuck run visible instead, which is this ticket's actual job.
- Double-spawn guard (return existing run state instead of starting a second one) — cheap, prevents a double-click or a second browser tab from launching two concurrent `claude -p` runs against the same ticket.
