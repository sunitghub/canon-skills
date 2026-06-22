# sprint-check-app

## Testing

Any change to `app.html` requires Playwright verification — not just grep-based tests.

- Run UI tests: `npm run test:ui` (requires the sprint-check server running — start with `npm run sprint-check`)
- Start server: `npm run sprint-check` (auto-selects a free port starting at 8423)
- Test file: `tests/sprint-check-app.spec.js`
- Ticket card selector: `.card`; create button: `#btn-create`
- `npm test` (bash suite) covers non-UI regressions; both must pass before `sprint complete`

## Port

The server starts on `127.0.0.1:8423` and auto-increments if that port is busy. The URL is printed to the terminal on startup.

## Architecture

Single-file app (`app.html`) served by a Python stdlib HTTP server (`server.py`). No build step. All JS, CSS, and HTML are inline. Edit `app.html` directly.

`server.py` exposes:
- `GET /api/tickets` — all tickets except `archived`; add `?all=1` to include archived
- `POST /api/ticket/<id>/status` — update ticket status
- `GET /api/handoff`, `/api/git`, `/api/why?file=<path>` — sidebar data
