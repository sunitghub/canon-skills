# sprint-check-app

## Testing

Any change to `app.html` requires Playwright verification — not just grep-based tests.

- Run UI tests: `npm run test:ui` (requires the sprint-check server running on port 8423)
- Start server: `python3 tools/sprint-check-app/server.py`
- Test file: `tests/sprint-check-app.spec.js`
- Ticket card selector: `.card`; create button: `#btn-create`
- `npm test` (bash suite) covers non-UI regressions; both must pass before `sprint complete`

## Port conflict

The server binds to `127.0.0.1:8423`. A process already on that port silently prevents the board from loading with no error message. Run `lsof -i :8423` to diagnose before starting.

## Architecture

Single-file app (`app.html`) served by a Python stdlib HTTP server (`server.py`). No build step. All JS, CSS, and HTML are inline. Edit `app.html` directly.

`server.py` exposes:
- `GET /api/tickets` — all tickets except `archived`; add `?all=1` to include archived
- `POST /api/ticket/<id>/status` — update ticket status
- `GET /api/handoff`, `/api/git`, `/api/why?file=<path>` — sidebar data
