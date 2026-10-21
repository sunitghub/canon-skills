# sprint-check-app

## Testing

Any change to `app.html` or `static/` requires Playwright verification — not just grep-based tests.

- **Full spec, the one way (t-4469): `tests/run-board-spec.sh`** (both browsers, 3 runs; `--runs 1 --browsers chromium --grep "<title>"` for a quick look). It copies the working tree (the gitignored `.tickets` included) to a temp dir, starts the Go board **from the copy**, runs `tests/sprint-check-app.spec.js`, proves canon's own tree did not change, then runs `tests/board-spec-guard.js` against `tests/board-spec-baseline.json`: exit 0 means every failure seen is listed there; a listed flaky test that failed every run only warns ("ok with N warning(s)"), and `--strict` makes warnings fail. Nothing may be skipped or go missing: an unlisted skip, a test missing from a run, or fewer tests than `min_tests` in the baseline is a violation (that is how a serial group's cascade skip, the old "9 did not run", would show). About 8 minutes per browser per run. When it finds failures that aren't in the baseline, `--classify --base origin/main` (t-b860) reruns each one alone (`--solo-runs`, default 3) on the copy and on a `git archive` copy of the base. It prints each failure's kind (timeout with the stalled call, assertion, error), its solo counts, and a baseline entry to paste only for a timeout that passed every solo run on both; everything else is a "likely regression". It never writes the baseline. For sprint evidence, stamp the full run with `--out .tickets/<id>/evidence/<dir>`: if you then only list flakes, stamp `node tests/board-spec-guard.js <dir>/board-spec-*-run*.json` at the new HEAD and `evidence.sh check` counts the run as `covered` (t-a3d7) instead of stale.
- **`scripts/test.sh` (t-2633)** prints each suite's time and the 10 slowest at the end of every run; `--list` prints every suite (the one list; `scripts/test-hermetic.sh` reads it). Since t-abb1 suites run in parallel, each with its own `TMPDIR`; a suite that shares state outside it (a fixed port, a folder under the repo) goes in test.sh's `SERIAL` list with its reason, and `--jobs 1` is the old sequential run.
- **Never run the spec against canon's own tree.** It writes and deletes tickets in its project root (ids from `Math.random` — `t-eb92`), and the board's `model-tiers.json` is shared state (since `t-5df2` it lives in `$CANON_HOME/cockpit/`; `run-board-spec.sh` pins `CANON_HOME` to a temp dir). It also gives each board its own `COCKPIT_STATE_DIR` and a `COCKPIT_DAEMON_BIN` that names no file, so a run never sees your live daemon or launches one that outlives it (t-2992).
- **An empty repo is not a baseline.** It once hid 9 tests per browser (the serial "Admin > Model Tiers" group skips the rest after one failure) and fails tests that expect a populated board. On a copy of the real tree, 351 tests run per browser, 0 skipped. Real-data numbers (5 runs per browser, 2026-10-04): chromium 1 failing and 10 flaky, webkit 0 failing and 15 flaky.
- **The baseline file.** `failing` = failed in every run: quarantined, with a ticket id and a `// QUARANTINE t-xxxx: reason` comment directly above the test in the spec; the test keeps running, and the guard warns when it starts passing. `flaky` = may fail any number of runs, including every run of one batch (the guard then warns): listed with a reason (a ticket when diagnosed). A new, unlisted failure is a violation: rerun it; if it passes, list it as flaky with evidence, otherwise it is a regression. Remove an entry in the same change that fixes its test. A marker matches the test line by its ticket id and the first 40 characters of the title, so a test whose title is built from a template literal cannot be quarantined: give it a static title first. To attribute a flaky test, alternate base and branch in one scratch copy (6 runs each), not sequential batches: `t-e946` read branch 3/5 right after base 0/8, then unmodified base 2/4.
- A run much slower than usual (about 13 min per browser run) fills the guard with timeout violations: compare run durations against the baseline before chasing them, then alternate base and branch on just the suspects (`--grep`) in a quiet window (`t-9b2d`).
- **A baseline from one batch of runs misses tests** (`t-6be9`): two clean-machine strict runs each failed on a different set of unlisted tests, and 6 of the first 8 never recurred. Build `flaky` from more than one batch and record machine load with each run.
- **A GET route that runs git or gh is a side-effecting route** (`t-d271`): give it the same cross-site (Origin) refusal as the POSTs.
- Run the spec by hand against a board you started yourself: `npm run test:ui` (start one with `(cd tools/canon-go && go run ./cmd/sprint-check 8423)`; `SPRINT_CHECK_BASE` overrides the default `http://localhost:8423`). `tests/sprint-check-go-ui.sh` runs a subset on an empty repo; `npm test` runs neither.
- The board is the Go board on every OS (t-15d8; `server.py` is gone). Uncommitted edits: `(cd tools/canon-go && go run ./cmd/sprint-check <port>)`. `canon` on macOS/Linux builds a committed but unreleased board from source (needs Go), and `scripts/release-daemon.sh` publishes the binaries before the push (`scripts/check-binaries-released.sh` checks it). Tests build it with `build_board` (`tests/helpers.sh`).
- Test file: `tests/sprint-check-app.spec.js`
- Ticket card selector: `.card`; create button: `#btn-create`
- `npm test` (bash suite) covers non-UI regressions; both must pass before `sprint complete`
- `scripts/test.sh`'s orphan check fails only on a board server that run itself started and left running (it carries the run's `CANON_TEST_RUN`, t-72e9): your own board, one you started for screenshots, or a board spec run alongside can stay up.
- Stamp the full board spec on a quiet machine, never beside `scripts/test.sh` or another spec run: WebKit under CPU contention went from 2-3 baselined failures to 8 and ran 21 % slower (t-5989). Running the passes at once is the same contention: 2 at once took 29.6 min with 7 new failures, 4 at once 22.8 min with 39, serial 55 min clean (`--runs 2`, t-2992, 2026-10-18), so the runner has no parallel mode. `tests/run-board-spec.sh` records the load in `$OUT/machine-load.txt` and prints a WARNING when the machine is busy; rerun before trusting failures from a warned run.
- Before moving board code out of a file, `git grep` every reader of that file repo-wide; Go tests in `tools/cockpit-daemon/` read board files too (`t-c58e`).
- Cockpit UI changes (`app.html` and `static/`, `cockpit.html`, the daemon page): also run the spec with `--browser=webkit` before `sprint complete` — Safari differs (e.g. it reports the shell as `event.source` for a board's message, t-67ab). Stub a daemon on a normal port (`FAKE_DAEMON_ADDR`): WebKit refuses restricted ports like 1 before a route can fulfil them (t-df8e).

## Writing board tests that hold under load

- Never `waitForTimeout` for something the page will tell you: poll the state (`expect.poll(() => page.evaluate(() => cockpitState.status))`). Twenty-four fixed 100 ms waits in the leave-session group (`t-359b`) are the suspected cause of its flakes. For a layout measurement after opening a modal, wait for the text and `getAnimations()` to finish (two tests passed only by luck at a fixed 700 ms); a scrolling-card test needs a dialog taller than the document (`t-5648`).
- Before pressing keys in a frame, wait until that frame's handler exists (`boardKeys` in the board); a key pressed earlier goes nowhere.
- Mock every new endpoint in the shared page helper so a real daemon or real data never leaks in; assert the stable part of UI strings, not the whole sentence.
- A menu that closes on `focusout` must exempt pointer clicks: WebKit does not focus a clicked button, so a click inside the menu reports a `focusout` with no `relatedTarget` and the menu closes before the click lands. Run the Tab-away test on webkit (`t-9d93`).
- Themes (t-4fa5): `static/theme-data.js` owns the themes (12 colours each), `derive()` (a theme -> the shell's and the board's variables) and the saved choice; both pages import it. Canon Dark/Light are the CSS; a third-party theme sets its variables inline on `<html>`. A colour in CSS that must follow the theme is `var(--th-<name>, <Canon colour>)`: Canon never sets `--th-*`, so it keeps its colour, and `derive()` must set every `--th-*` the CSS reads. Changing a token can make it equal another (`--bg` vs `--border-muted`) and erase what paints one over the other: scan the rendered page's computed colours, `:hover` included, for pairs that collapse (`t-83c9`). A new literal colour fails `tests/sprint-check-theme.js` (its scan lists the few allowed ones).
- User themes (t-f889): `$CANON_HOME/themes/*.json` are untrusted files. `sprint-check-go` and `theme-data.js`'s `checkTheme()`/`validateTheme()` each check them with the same rules and reason strings; change both together, plus `theme.schema.json` and `docs/custom-themes.md`, and run `tests/theme-files-parity.sh` (corpus, fuzz, Open themes folder with a stub `CANON_OPEN_BIN`). The spec's `beforeEach` routes `/api/themes` and `/api/themes/open` to empty stubs, so no test reads this machine's folder or opens it; route them per test.
- A keyboard test that Tabs through buttons needs `Alt+Tab` in WebKit: Safari's default Tab skips buttons (its "Press Tab to highlight each item" setting is off), so plain `Tab` lands on the next text field (t-2758).
- `expect.poll(fn).toBe(await other())` evaluates the expected value once, up front, so two empty sides pass vacuously. Compute both sides inside the poll, start from a state that differs from the expected one (or await a page-exposed "fetch applied" flag), and prove it with a revert mutant (`t-a205`, `t-4487`).
- Use `pwd -P` for temp roots on macOS (`mktemp -d` returns a `/var` symlink), and record which board and which data a count came from.
- A helper that a vm-loaded unit test (the `tests/sprint-check-*.js` pattern) exercises must be self-contained: reusing a top-level `const` makes every case throw.
- When a fixed-width container gains or hides items, assert where things are: each control's bounding box lies inside the container, and items that belong on one row share a `top`. `toBeVisible`/`toBeEnabled` still pass for a control that is clipped or wrapped. When you hide a duplicate, prove the surviving copy cannot be clipped away (`t-614c`, `t-824e`).
- A screenshot for one theme must show the embedded boards in that theme too: set the theme through the app's real path (not only the shell's `data-theme`), wait out the 0.12 s fade, and look at the iframe content before using the shot as evidence (`t-9a6c`, `t-bcce`).
- A Test Plan line that names a set ("each converted button") gets a script that shoots the set and checks its own coverage against the named list. A flex row stretches its children to one height, so check padding and radius, not height (`t-e523`).
- A rule on a container's children (`.foot button{max-width}`) also hits components nested inside it: when restyling, render every nested component (`t-2758`).
- Covering a view with an overlay is not hiding it: the covered iframe keeps focus and tab order. Mark it `inert`, make focus code skip it, and grep the in-page help sheet when a UI rule is retired (`t-bcce`).

## Board root redirect (t-5716)

A top-level browser visit to `/` (`Sec-Fetch-Dest: document`) redirects to `/cockpit` (`/cockpit#open=<id>` with `?project=`). The spec's `beforeEach` route adds `?standalone=1` to top-level `/` navigations so existing tests reach the board; set `realLanding = true` in a test that needs the real redirect. iframes and header-less clients (curl) are served the board as before.

## Port

The Go board starts on `127.0.0.1:8423` (the `canon` and `sprint-check` launchers pass 8899) and moves to the next free port if that one is busy. The URL is printed to the terminal on startup.

## Toggleable Badges

Put a badge's initial hidden state in an inline `style="display:none"` HTML attribute, not the CSS class rule. `element.style.display = ''` only clears an inline override — it can't override a `display: none` baked into the class's own stylesheet rule, so JS toggling silently does nothing. See `#s-modified`/`#s-commits-total` for the working convention (t-9cde).

## Drop Gates

Client-side drop gates in the board's scripts (`static/board-*.js`) depend on server-computed fields from the Go board (`tools/canon-go/internal/board`). When writing acceptance criteria for a gate, name the exact server field — not just the user-visible behavior. "Blocked when `acceptance_unchecked` is true" is testable; "blocked when acceptance has unchecked items" is ambiguous and can mask a wrong field being used (see t-0b5c).

## Stubbing external binaries in tests

Never swap a real script under `tools/` in place to stub it for a test (a same-process
`finally`/`trap` restore can't survive an uncatchable kill mid-test — see `t-1781`). Point
`main.go` at a temp stub via an env-var override instead — `COCKPIT_DAEMON_BIN`,
`SPRINT_HEADLESS_BIN`, `SPRINT_HEADLESS_EVAL_BIN` are the existing pattern to follow for any
new one.

## New element ids

Grep for an id prefix before using it — the cockpit rail already owns `ck-tc-*` (ticket card: `ck-tc-status`, `ck-tc-title`, …). A duplicate id makes `getElementById` return the first match with no error, so a new widget silently writes into another one (t-d254's commit dialog did, until renamed to `ck-tcm-*`).

## Architecture

`app.html` (markup only) plus `static/` (CSS and scripts), served by the Go board (`tools/canon-go/internal/board`) at `GET /static/<name>` (flat lowercase `.css`/`.js` names only). No build step (`t-9b2d`, `t-c58e`, `t-1543`):
- CSS lives in `static/board-*.css`, linked in cascade order; edit the file for the section, never add a `<style>` back.
- The script is native ES modules. `app.html` loads only `static/board-main.js`, plus one exception: the classic, blocking `static/theme-boot.js` in `<head>` (t-2758, amends t-1543), which sets the saved theme (and a third-party theme's cached variables, validated) before the first paint and defines nothing. Never add another `<script>` or a `window` bridge. The board's code is `static/board-{core,helpers,render,modal,docs,cockpit,cockpit-rail,worktree,panels,create,ui,github}.js` plus `static/editor.js`. Put new code in the module for its section and `import` what it uses from the others (`./board-x.js`).
- A module only declares: no top-level statement runs at load, because an import cycle evaluates files out of order and would read another file's `let`/`const` before it exists. Load-time code (listeners, boot calls) goes in that file's exported `init<File>()`, which `board-main.js` calls in the order above.
- An importer cannot assign an imported binding. A `let` other files change gets a function in its own module (`stopCockpitPoll()`, `nextPasteVisualIndex()`).
- Nothing is a global any more. Playwright reaches board code with `await import('/static/board-<x>.js')` inside `page.evaluate` (the page's own module instance), never `window.<name>`; read a reassigned `let` through the namespace (`(await import(...)).cockpitState`) so it stays live.
- Grep tests read `board_sources` (`tests/helpers.sh`), not `app.html` alone. Node unit tests load the board's exports through `tests/board-script.js` (Node `require()` of the modules, stub globals, Node 22.12+) or import a module directly (`tests/sprint-check-editor.js`). `static/package.json` marks the folder as ES modules for Node; the boards never serve it.

The board exposes (among others):
- `GET /api/tickets` — all tickets except `archived`; add `?all=1` to include archived
- `POST /api/ticket/<id>/status` — update ticket status
- `GET /api/handoff`, `/api/git`, `/api/why?file=<path>` — sidebar data

Per-ticket doc tabs (Description/Decisions/Acceptance/Plan/...) are **generated generically** from any `*.md` file in `.tickets/<id>/` except `ticket.md` — the tab name is the filename title-cased (`tools/canon-go/internal/board/main.go`'s `docName`, pinned by `tests/sprint-check-api.sh`). Only `eval-report.md` and `review-notes.md` are special-cased: they show as "Eval Agent" / "Review Agent" and sort right after Acceptance, Plan and Research, Review before Eval (t-1f22); every other file is listed by name after them, so writing a new `.tickets/<id>/foo-bar.md` file still produces a "Foo Bar" tab with zero board code changes (t-022f).

The Cockpit shell (`cockpit.html`, served at `/cockpit`) follows the same split (t-783a). Its CSS lives in `static/cockpit-{shell,admin,upkeep,projects}.css`, linked in cascade order, so never add a `<style>` back. Its controls are wired with `addEventListener`: static markup in a `DOMContentLoaded` block beside the section's code, and generated HTML right after the `innerHTML` that builds it. Never add an inline `on*=` handler: a spec test fails on any, and modules can't serve globals to attributes.
Its script is native ES modules, with the same rules as the board (t-565f). `cockpit.html` loads only `static/cockpit-main.js` (and the same `static/theme-boot.js` in `<head>`, t-2758), which runs each module's `init<Section>()` in the old order. The modules are `static/cockpit-{core,theme,sessions,sidebar,keys,views,upkeep,skill-eval,admin,tabs,projects,end}.js`; each only declares, and there are no shell globals. State another module writes gets an owner function (`getProjects()`, `setLastSessions()`, `setUpkeepPane()`). The spec reaches shell code with `await import('/static/cockpit-<x>.js')` inside `page.evaluate`. Test suites read the shell through `shell_sources` (`tests/helpers.sh`), and `board_sources` excludes the `cockpit-*` files.

`cockpit.html`'s reusable `cockpitConfirm()` dialog (`#cconfirm`) has exactly one markup instance, always wrapped in `.cmodal` — a `.cmodal`-scoped CSS rule applies to it too, not just the close-tab warning modal it looks like it's scoped for. Check DOM nesting before assuming a `.cmodal`-scoped rule doesn't reach `#cc-ok`/`#cc-cancel` (t-a30c).

In the shell, ask a pane's `contentDocument.hasFocus()`, not `document.activeElement`: after the shell focuses an iframe by script, a later click into a sibling iframe leaves `activeElement` pointing at the old one (t-416c).

Heading slugs for a child row and for the rendered heading must derive from the same text the reader sees (`textContent`): a heading containing a link or image gives two slugs and the row scrolls nowhere. Test a heading with markup (`t-612f`).

## Gate model dropdown and the Model Tiers registry (moved from AGENTS.md, t-8837)

The board's per-ticket `Gate model:` dropdown (`tools/sprint-check-app/app.html`) reads its live
option list from `tools/sprint-check-app/model-tiers.json` (Admin > Model Tiers, `t-7e36`) —
that file is a seeded, editable mirror of the Anthropic models named above, not a replacement for
this prose; the registry's OpenAI entries run close gates only per ticket, via `Gate model: openai:<id>` under Copilot CLI (`t-ef27`); the Admin OpenAI defaults stay recorded only.
Since `t-5df2` the board writes Admin edits to `$CANON_HOME/cockpit/model-tiers.json` (default `~/.canon/cockpit/`) and reads it before the tracked file, which stays a read-only seed.
