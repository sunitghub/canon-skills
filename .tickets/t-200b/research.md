# Research

Ticket: `t-200b`

## Objective
Whether/how sprint-check's two backends can trigger and poll a long-running `sprint-headless` run, and what's genuinely new vs. reusable from existing patterns.

## Relevant Files
| File | Why relevant | Evidence |
|---|---|---|
| `tools/sprint-check-app/server.py:555-643` | `do_GET`/`do_POST` — all existing routes are fast, synchronous, regex-dispatched on `path` | e.g. `m = re.match(r'^/api/ticket/([^/]+)/status$', path)` then an immediate `send_json` |
| `tools/sprint-check-app/server.py:224-229` | Only existing subprocess precedent — `run()`, a blocking `subprocess.check_output` with a **5-second timeout** | `timeout=5).strip()` |
| `tools/sprint-check-app/server.py:669-681` | Server accepts each connection into its own daemon thread | `threading.Thread(target=handle_conn, args=(conn, addr), daemon=True).start()` |
| `tools/sprint-check-app/server.py:598-603` | Existing CSRF-ish protection already present on POST: `_host_ok()` (binds 127.0.0.1 only) + Origin-header check | `if origin and not origin.startswith('http://127.0.0.1') and not origin.startswith('http://localhost'): self.send_error(403)` |
| `tools/sprint-check-go/main.go:130,908` | Go's `net/http` gives goroutine-per-request concurrency for free (standard library default); `exec.Command("git", ...)` is the only existing subprocess precedent, same blocking-with-short-scope pattern as Python's `run()` | — |
| `tools/sprint-headless:18-42` | Own strict validation already exists: ticket ID `^t-[a-z0-9]{4}$`, base-ref `^[A-Za-z0-9._/-]+$` — both enforced before either ever reaches a subprocess argument | — |
| `tools/sprint-check-app/CLAUDE.md:5` | Any `app.html` change requires Playwright verification, not just grep-based tests | — |
| `t-978c` (closed) | Precedent: a pure data-flow UI change needed **zero** backend code changes in either language, because both backends already generically pass frontmatter through | `DECISIONS.md` 2026-07-12 entry |

## System Model
- **Concurrency is not a blocker in either backend.** Python: each connection already gets its own daemon thread, so a long-running POST's handler thread doesn't block other requests (existing GETs/polls proceed independently). Go: `net/http`'s standard library already goroutines every request. Neither backend needs new concurrency infrastructure — just an async-execution *pattern* (kick off + poll) neither currently has.
- **This ticket is NOT free like `t-978c`.** The CI badge only needed a frontend change because both backends already passed the relevant data through generically. Triggering and tracking a background process is genuinely new server-side logic — an in-memory run-state store, a background thread/goroutine that runs `sprint-headless` to completion, and a poll endpoint reading that state — and it has to be written **twice**, once per backend, since neither has this capability today. `app.html`'s shared-frontend advantage still applies to the UI/polling-loop code, but not to the actual subprocess-execution logic.
- **`tools/sprint-headless` is a sibling of both servers on disk**, not something that needs `$PATH` resolution: `server.py` lives at `tools/sprint-check-app/server.py`, `main.go` at `tools/sprint-check-go/main.go` — both can reference `tools/sprint-headless` via a path relative to their own known location (`Path(__file__).parent.parent / 'sprint-headless'` in Python; the Go equivalent using its own binary/source location), avoiding any dependency on the invoking user's shell `$PATH` at all. This sidesteps the whole `t-9737`/`t-d351` PATH-resolution problem class entirely, since the server process's own location is always known.
- **No shell-injection risk regardless of input validation**, because `subprocess.Popen`/`exec.Command` with an argument list (not a shell string) never invokes a shell — `ref; rm -rf /` style payloads are inert as a single argv element either way. Validating ticket-id/base-ref server-side before spawning is still worth doing (defense in depth, a clean 400 instead of deferring to the subprocess's own error, consistent with existing endpoint patterns like the image-serving route's `t-[a-z0-9]{4}` regex), but it is not the only thing standing between user input and command execution.
- **Auth/API-key requirement is not new plumbing to add** — the server process inherits whatever environment (and `claude` CLI authentication) the user already has locally, same as running `sprint-headless` by hand in a terminal. If `claude -p` fails (no auth, rate limit), `sprint-headless` already surfaces that as `HEADLESS_VERDICT` absence and a hard-fail message (per its existing `is_error` handling) — the new endpoint's job is to surface that failure text to the UI, not to suppress or reinterpret it.
- Since `t-1bea` closed, `sprint-headless` now writes real `review-notes.md`/`eval-report.md` files on success — the polling endpoint can read those once the process completes, rather than needing to buffer/parse raw stdout itself (this was `t-200b`'s own noted dependency on `t-1bea`, now satisfied).

## Constraints
- `docs/headless-ci.md`'s existing warning still applies: running this "only in an isolated, secret-scoped CI environment" was about CI; here the analogous constraint is that this only runs against the user's own local machine/auth, same trust boundary as them running the CLI directly — no new remote-trust boundary is being crossed.
- `tools/sprint-check-app/CLAUDE.md` mandates Playwright verification for any `app.html` change — a UI trigger + polling display needs real Playwright coverage, not grep-based tests, consistent with `t-978c`'s own testing approach.
- Server-side in-memory run state does not survive a server restart — a run in progress when the server restarts would be silently lost from the UI's perspective (the underlying `sprint-headless` subprocess itself would also die, since it's a child of the server process). This needs an explicit decision: acceptable limitation (document it) vs. something to guard against (e.g. reject a new trigger if state file suggests one's already running, engineering a bigger persistence story) — flagged for grill, not decided here.

## Unknowns
- Base-ref input UX (free text vs. dropdown of recent commits) — flagged in the ticket itself, not resolved by research; a genuine product decision, not a technical one.
- Polling vs. streaming (SSE/websocket) — technically both are reachable given the concurrency model above; the choice is about UX responsiveness vs. implementation complexity, not feasibility.
- Whether full Go-backend parity is in scope for this same pass, given it roughly doubles implementation and test surface compared to `t-978c`'s zero-backend-change precedent — surfaced for the user's explicit call, not assumed either way.

## Not In Scope
- Any change to `tools/sprint-headless` itself — this ticket only adds a caller, it doesn't change the script's own behavior (already closed via `t-1bea`/`t-af61`/`t-c368`).
- Ticket-status/close mutation from this new endpoint — same explicit boundary as `t-1bea`, `sprint-headless` (and now this UI trigger for it) never closes a ticket.
