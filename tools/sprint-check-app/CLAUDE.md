# sprint-check-app

## Testing

Any change to `app.html` requires Playwright verification — not just grep-based tests.

- **Full spec, the one way (t-4469): `tests/run-board-spec.sh`** (both browsers, 3 runs; `--runs 1 --browsers chromium --grep "<title>"` for a quick look). It copies the working tree (the gitignored `.tickets` included) to a temp dir, starts the Go board **from the copy**, runs `tests/sprint-check-app.spec.js`, proves canon's own tree did not change, then runs `tests/board-spec-guard.js` against `tests/board-spec-baseline.json`: exit 0 means every failure seen is listed there; a listed flaky test that failed every run only warns ("ok with N warning(s)"), and `--strict` makes warnings fail. Nothing may be skipped or go missing: an unlisted skip, a test missing from a run, or fewer tests than `min_tests` in the baseline is a violation (that is how a serial group's cascade skip, the old "9 did not run", would show). About 8 minutes per browser per run.
- **Never run the spec against canon's own tree.** It writes and deletes tickets in its project root (ids from `Math.random` — `t-eb92`), and the board's `model-tiers.json` is shared state (since `t-5df2` it lives in `$CANON_HOME/cockpit/`; `run-board-spec.sh` pins `CANON_HOME` to a temp dir).
- **An empty repo is not a baseline.** It once hid 9 tests per browser (the serial "Admin > Model Tiers" group skips the rest after one failure) and fails tests that expect a populated board. On a copy of the real tree, 351 tests run per browser, 0 skipped. Real-data numbers (5 runs per browser, 2026-10-04): chromium 1 failing and 10 flaky, webkit 0 failing and 15 flaky.
- **The baseline file.** `failing` = failed in every run: quarantined, with a ticket id and a `// QUARANTINE t-xxxx: reason` comment directly above the test in the spec; the test keeps running, and the guard warns when it starts passing. `flaky` = may fail any number of runs, including every run of one batch (the guard then warns): listed with a reason (a ticket when diagnosed). A new, unlisted failure is a violation: rerun it; if it passes, list it as flaky with evidence, otherwise it is a regression. Remove an entry in the same change that fixes its test. A marker matches the test line by its ticket id and the first 40 characters of the title, so a test whose title is built from a template literal cannot be quarantined: give it a static title first.
- Run the spec by hand against a board you started yourself: `npm run test:ui` (the board must already be running — `npm run sprint-check`; port 8423 is the default, `SPRINT_CHECK_BASE` overrides). `tests/sprint-check-go-ui.sh` runs a subset on an empty repo; `npm test` runs neither.
- Start server: `npm run sprint-check` (auto-selects a free port starting at 8423)
- Test file: `tests/sprint-check-app.spec.js`
- Ticket card selector: `.card`; create button: `#btn-create`
- `npm test` (bash suite) covers non-UI regressions; both must pass before `sprint complete`
- Cockpit UI changes (`app.html`, `cockpit.html`, the daemon page): also run the spec with `--browser=webkit` before `sprint complete` — Safari differs (e.g. it reports the shell as `event.source` for a board's message, t-67ab). Stub a daemon on a normal port (`FAKE_DAEMON_ADDR`): WebKit refuses restricted ports like 1 before a route can fulfil them (t-df8e).

## Writing board tests that hold under load

- Never `waitForTimeout` for something the page will tell you: poll the state (`expect.poll(() => page.evaluate(() => cockpitState.status))`). Twenty-four fixed 100 ms waits in the leave-session group (`t-359b`) are the suspected cause of its flakes.
- Before pressing keys in a frame, wait until that frame's handler exists (`boardKeys` in the board); a key pressed earlier goes nowhere.
- Mock every new endpoint in the shared page helper so a real daemon or real data never leaks in; assert the stable part of UI strings, not the whole sentence.
- Use `pwd -P` for temp roots on macOS (`mktemp -d` returns a `/var` symlink), and record which board and which data a count came from.
- A helper that a vm-loaded unit test (the `tests/sprint-check-*.js` pattern) exercises must be self-contained: reusing a top-level `const` makes every case throw.
- When a fixed-width container gains or hides items, assert where things are: each control's bounding box lies inside the container, and items that belong on one row share a `top`. `toBeVisible`/`toBeEnabled` still pass for a control that is clipped or wrapped. When you hide a duplicate, prove the surviving copy cannot be clipped away (`t-614c`, `t-824e`).
- A screenshot for one theme must show the embedded boards in that theme too: set the theme through the app's real path (not only the shell's `data-theme`), wait out the 0.12 s fade, and look at the iframe content before using the shot as evidence (`t-9a6c`, `t-bcce`).
- Covering a view with an overlay is not hiding it: the covered iframe keeps focus and tab order. Mark it `inert`, make focus code skip it, and grep the in-page help sheet when a UI rule is retired (`t-bcce`).

## Board root redirect (t-5716)

A top-level browser visit to `/` (`Sec-Fetch-Dest: document`) redirects to `/cockpit` (`/cockpit#open=<id>` with `?project=`), in both servers. The spec's `beforeEach` route adds `?standalone=1` to top-level `/` navigations so existing tests reach the board; set `realLanding = true` in a test that needs the real redirect. iframes and header-less clients (curl) are served the board as before.

## Port

The server starts on `127.0.0.1:8423` and auto-increments if that port is busy. The URL is printed to the terminal on startup.

## Toggleable Badges

Put a badge's initial hidden state in an inline `style="display:none"` HTML attribute, not the CSS class rule. `element.style.display = ''` only clears an inline override — it can't override a `display: none` baked into the class's own stylesheet rule, so JS toggling silently does nothing. See `#s-modified`/`#s-commits-total` for the working convention (t-9cde).

## Drop Gates

Client-side drop gates in `app.html` depend on server-computed fields from `server.py`. When writing acceptance criteria for a gate, name the exact server field — not just the user-visible behavior. "Blocked when `acceptance_unchecked` is true" is testable; "blocked when acceptance has unchecked items" is ambiguous and can mask a wrong field being used (see t-0b5c).

## Stubbing external binaries in tests

Never swap a real script under `tools/` in place to stub it for a test (a same-process
`finally`/`trap` restore can't survive an uncatchable kill mid-test — see `t-1781`). Point
`server.py`/`main.go` at a temp stub via an env-var override instead — `COCKPIT_DAEMON_BIN`,
`SPRINT_HEADLESS_BIN`, `SPRINT_HEADLESS_EVAL_BIN` are the existing pattern to follow for any
new one.

## New element ids

Grep for an id prefix before using it — the cockpit rail already owns `ck-tc-*` (ticket card: `ck-tc-status`, `ck-tc-title`, …). A duplicate id makes `getElementById` return the first match with no error, so a new widget silently writes into another one (t-d254's commit dialog did, until renamed to `ck-tcm-*`).

## Architecture

Single-file app (`app.html`) served by a Python stdlib HTTP server (`server.py`). No build step. All JS, CSS, and HTML are inline. Edit `app.html` directly.

`server.py` exposes:
- `GET /api/tickets` — all tickets except `archived`; add `?all=1` to include archived
- `POST /api/ticket/<id>/status` — update ticket status
- `GET /api/handoff`, `/api/git`, `/api/why?file=<path>` — sidebar data

Per-ticket doc tabs (Description/Decisions/Acceptance/Plan/...) are **generated generically** from any `*.md` file in `.tickets/<id>/` except `ticket.md` — the tab name is just the filename title-cased (`server.py:332`'s `_doc_name`, `sprint-check-go/main.go:534` parity). There is no special-cased "Decisions" (or any other) tab — writing a new `.tickets/<id>/foo-bar.md` file automatically produces a "Foo Bar" tab with zero board code changes (t-022f).

`cockpit.html`'s reusable `cockpitConfirm()` dialog (`#cconfirm`) has exactly one markup instance, always wrapped in `.cmodal` — a `.cmodal`-scoped CSS rule applies to it too, not just the close-tab warning modal it looks like it's scoped for. Check DOM nesting before assuming a `.cmodal`-scoped rule doesn't reach `#cc-ok`/`#cc-cancel` (t-a30c).

In the shell, ask a pane's `contentDocument.hasFocus()`, not `document.activeElement`: after the shell focuses an iframe by script, a later click into a sibling iframe leaves `activeElement` pointing at the old one (t-416c).
