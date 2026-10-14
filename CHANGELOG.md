# Changelog

All notable changes to canon are listed here, newest first, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

**Versioning.** The number in `VERSION` is [SemVer](https://semver.org): a patch for fixes, a minor for new features that keep working as before, a major for a change that breaks a tool's command line or the install layout. A release is a `VERSION` bump, a dated section below, and an annotated tag `vX.Y.Z` on the public repo, made by `scripts/release.sh` (see `docs/releasing.md`). Commits between releases are listed under Unreleased. To stay on a release, or go back to one: `canon update --to vX.Y.Z`.

## [Unreleased]

### Changed
- Cockpit: **◐ Theme** replaces the sidebar's Dark/Light button. It opens a small panel with Mode (System, Light or Dark; System follows your computer) and the theme for that mode, one pick for light and one for dark under System; hover the button to see the theme in use. Canon Dark and Canon Light look as before (`t-2758`).
- Cockpit: six more themes, Catppuccin Mocha and Latte, Tokyo Night, Nord, Dracula and Gruvbox Dark, each from its project's own palette and readable at WCAG AA; hover a theme to preview it, click to keep it. The shell and every open board follow, from the first frame. Credits and licences are in `THEMES.md` (`t-4fa5`). The terminal stays dark for now (`t-2ba3`).

### Fixed
- A light-theme user no longer sees a dark first frame when the Cockpit or a board loads (`t-3735`).
- A board in a Cockpit tab no longer overwrites the standalone board's own saved theme, and a board now accepts a theme change only from the Cockpit window that holds it (`t-2758`).
- A board that reloads, or is still loading when you change the theme, now shows the current theme, and a second Cockpit window follows a theme change instead of undoing it (`t-2758`).
- The sidebar footer buttons stop growing on a wide sidebar and stay centred, and the keyboard-shortcuts button is a little larger (`t-2758`).

## [0.8.0] - 2026-10-13

New tickets start from a short intent skeleton, and a development-version install no longer prints its notice twice.

### Fixed
- `install.sh` with `CANON_REF=main` printed the development-version notice twice (once from the `canon update` it runs, then its own copy); it now prints it once and ends with "Installed the development version (main)." (`t-bb84`).

### Changed
- A new ticket starts from an intent skeleton: `## Problem`, `## Outcome`, `## Constraints` and `## Open questions` (a bug also gets `## Expected` and `## Actual`), each followed by a one-line hint in an HTML comment: the New ticket form shows it as a prompt, and the board hides it once the ticket renders. The board's New ticket form, `tkt create` without `-d`, and a create request to either board with no body all give the same text; `-d` text and a body you cleared are kept as given. At sprint start the plan answers each open question or carries it forward by name, and the board's Plan template now matches the one `sprint start` writes (`t-b0c9`).
- `docs/releasing.md` now gives the push order for a Go change (release and verify the binaries before `public`), checks the branch before a bump, and refreshes getcanon.dev's version badge after a release; `docs/setup.md` explains the uncommitted `.gitignore` lines canon writes (`t-e6d2`).

## [0.7.0] - 2026-10-13

You can now end a Cockpit session you aren't attached to, a new project's first sprint closes without tripping over canon's own setup, and installs that follow `main` say so in plain words.

**After updating, restart the Cockpit daemon** (Admin > Restart) so Reap now and Kill are available: `canon update` fetches the new daemon, but a running one stays on the old version until it restarts.

### Added
- Cockpit: **Reap now** and **Kill** for a session you aren't attached to. Right-click its row under Agents (or Shift+F10, or Ctrl+. then `t` for the active tab's session); Admin's session rows have the same buttons. Reap now saves and ends, as the idle reaper would, and isn't offered while a session needs you, is working or shows a Copilot menu; Kill ends at once without saving. Both ask first, and Kill's dialog opens on Cancel. A scratch session's leftovers are noted in HANDOFF.md and its chip closes (`t-3c9a`).

### Fixed
- A new project's first `sprint complete` was refused because registering canon's skills edits the project's tracked `.gitignore` (and `.gitattributes`) and leaves the edit uncommitted. The close check now lets those two files through when they are exactly what canon's own setup makes of them, and still refuses any other change in them (`t-52f0`).

### Changed
- On the development version (main), the installers, `canon update` and `canon version` now say so in plain words — "You're on the development version (main): the newest changes, before they're released and without a release's verification." — and name the one command for the latest release, `canon update --to latest`. `canon version` reads `canon <version> (development version, following main)`; `canon --help` and `docs/setup.md` use the same words. The old wording ("not checksum-verified", "returns to verified releases") is gone (`t-d744`).
- `docs/agent-playbook.md`: approval binds to the exact proposal a human reviewed (re-checked before applying, end state verified), and a credential broker keeps tokens out of the agent's sandbox, with the existing hand-off rules as the fallback.

## [0.6.0] - 2026-10-12

The Cockpit's agent rows show which project each session is in and how long it has run; the Model Tiers seed adds the 5.5 models; an escaping hole that let a quote in a path or a skill's output break out of an HTML attribute is closed on every page. The Cockpit shell's code is split out of `cockpit.html` the way the board's was, with nothing changing on screen.

**If you edited Admin > Model Tiers:** your saved copy (`~/.canon/cockpit/model-tiers.json`) is read before the new seed, so the 5.5 models don't appear there. To get them, rename or delete that file (under `$CANON_HOME/cockpit/` if you set `CANON_HOME`) and reload the Cockpit; it falls back to the new seed. Then re-apply your own edits in Admin.

### Added
- Cockpit sidebar: each Agents row has a third line with the project and the time spent in the session so far (`ToDo · 32m in session`, or `ToDo · 1h 30m` when it would be cut off); the hover tip has everything, including the start time. Admin's session row ends with the same total (`t-aca6`).
- Admin > Model Tiers seeds Claude Sonnet 5.5, Claude Haiku 5.5 and gpt-6.1-sol; the Light tier now defaults to Haiku 5.5 (`t-99b2`).
- `sprint check-review-notes <id>` checks a reviewer's `review-notes.md` with the same rule `sprint complete` enforces; the reviewer runs it before returning and the orchestrator right after the dispatch, so a malformed report is rewritten at once instead of refused at close (`t-c38e`).

### Changed
- The Cockpit shell's CSS and script load from `tools/sprint-check-app/static/` (four `cockpit-*.css` files, and ten ES modules behind `static/cockpit-main.js`), and its inline `onclick` handlers are listeners. Nothing changes on screen (`t-783a`, `t-565f`).
- Sprint research asks what *reads* a changed file (every reader, sibling, test and fixture), not only what imports it (`t-e17d`).

### Fixed
- Cockpit sidebar: the version number sits next to "Canon Cockpit" instead of at the far edge of the row when the sidebar has spare width, as on Windows (`t-9f20`).
- Cockpit, light theme: the active tab reads as filled, like the dark theme — the light background deepens to `#e8e8f0`, so the tab still merges into the board below it; the Model Tiers tab underline keeps its contrast (`t-83c9`).
- Board: clicking a "why" alternative-path link runs the search instead of throwing `apply is not defined` (`t-10dc`).
- Board docs: an image whose file name contains `&` (or a quote) now loads (`t-d2e1`).

### Security
- Both pages' `esc()` now escape `"` and `'`, so a value with a quote can no longer close an HTML attribute and add an event handler. The exposed values included a skill run's output in the Upkeep tooltip, worktree paths and branch names. Four server values that reached the page with no escaping at all are escaped too: the Skill Eval status and case counts, the commit panel's in-progress ticket id, and the outcome counts on board cards (`t-d2e1`).

## [0.5.0] - 2026-10-11

The board's code is split out of `app.html` into `static/` (CSS files and ES modules behind one entry), with nothing changing on screen. A version bump no longer changes the release binaries, so the cockpit daemon reports the installed version. The test suite runs from a worktree and keeps git's hook environment out.

### Changed
- The board's CSS and the doc editor's key handling load from `tools/sprint-check-app/static/` (`GET /static/<name>`, both servers, no build step); `app.html` is 2,000 lines shorter (`t-9b2d`).
- The board's main script loads from eleven `static/board-*.js` files instead of one inline script in `app.html`, which is now markup only (615 lines, from 6,808). Nothing changes on screen; a page load makes 11 more same-origin requests (`t-c58e`).
- Those eleven files are now ES modules loaded by one entry, `static/board-main.js`, and the board no longer puts its functions on `window`. Nothing changes on screen. The board's Node tests need Node 22.12 or later (they `require()` the modules) (`t-1543`).
- docs/learnings.md walks through a worked example of the learnings flow in a consumer project (`t-fb09`).
- docs/setup.md explains how `canon update` works: the two tracks, what it does for each kind of install, and every refusal (`t-153f`).

### Fixed
- A version bump no longer changes the release binaries: they read `VERSION` from the install, so the cockpit daemon now reports the installed version (a 0.4.0 install showed 0.3.0), and `scripts/release-daemon.sh` writes its own manifest when an older release's asset differs from today's build instead of stopping (`t-0859`, `t-7f09`).
- `tools/sprint-headless-eval` finds its repository when canon is a linked worktree (`.git` is a file there), and the test suite runs from a worktree and from a checkout under a symlinked path such as macOS `/var`; `tests/skills-uninstall.sh` now works on a scratch copy and no longer overwrites a checkout's `.claude/settings.json` or deletes its pre-commit hook (`t-1cfc`, `t-80fc`).
- The pre-commit hook no longer hands git's own repository (`GIT_DIR`, `GIT_INDEX_FILE`, `GIT_WORK_TREE`, `GIT_PREFIX`) to your test suite; a suite that ran `git init` or `git config` in a temp directory could change the real repository (`t-ce0b`). Run `canon update` to refresh the installed hook.
- The review and evaluation gates are told never to run `canon update`, `skills.sh`, `install.sh`, an uninstall or the daemon without a pinned `HOME`, `CANON_HOME`, `TMPDIR` and `XDG_CONFIG_HOME` (`t-ce0b`).

## [0.4.0] - 2026-10-09

Updates are verified by default: `canon update` and the installers take the latest verified release (`main` is now the opt-in). The shipped binaries are built with a pinned Go 1.27.2, which clears the vulnerabilities found in Go 1.27.1. If you are on v0.3.0, run `canon update --to main` once (its older updater does not know `--to latest`); after that a plain `canon update` is enough.

### Added
- Releases are verified: `canon update --to vX.Y.Z` (git installs) and the Windows installer check the release against the published manifest at getcanon.dev/releases.txt, and refuse, changing nothing, if it is unreachable, missing, malformed or disagrees. The Windows zip is checked against its SHA-256 before extraction. `main` stays unverified and says so (`t-34f1`).
- `scripts/release-zip.sh` builds the release zip; `scripts/release.sh` attaches it to the GitHub release and prints the manifest line.
- Gate runtime: `tools/evidence.sh stamp` writes builder evidence that names the commit it tested, `check` says whether a log is still fresh, and the evaluator reuses a fresh log for repeats of the same command while still running its own floor (changed suites, mutants, a spot-check) under a 25-minute budget; the evaluator's minutes are now recorded in the Wrapup Gates `eval` row (`t-e3cd`).
- Skill evals on change: `sprint complete` runs the evals of any skill whose instructions (or a gate agent) the sprint edited, advisory only, and records the pass rate in `skills/<name>/evals/history.jsonl` (`tools/skill-eval-scope.sh`, `tools/skill-eval-history.sh`); a defect traced to a skill's own instructions can become an `evals.json` case (`t-8d28`).

### Changed
- `canon update` and the installers follow the latest verified release by default, like most software; `main` is the opt-in development track (`canon update --to main`, `CANON_REF=main`). The newest release is read from the same published manifest as `--to vX.Y.Z` (`tools/release-manifest.sh --latest`, numeric order, same checks, no fallback). An install made before this moves to the latest release on its next plain update, once, with a message (local commits or uncommitted changes refuse, changing nothing). A rollback with `--to vX.Y.Z` is not sticky (from v0.4.0: v0.3.0's older updater still refuses a plain update as pinned; run `canon update --to main` once). `canon version` says when the install follows main. A new install that cannot verify a release installs nothing (`t-65c9`).

### Security
- The prebuilt binaries are built with a pinned Go 1.27.2, not whatever Go is installed: `toolchain go1.27.2` in `tools/cockpit-daemon/go.mod`, and a `GO_TOOLCHAIN` file in `tools/sprint-check-go` and `tools/sprint-headless-json-go` that `scripts/release-daemon.sh` builds with. Go 1.27.1 had 6 net/http and HTTP/2 vulnerabilities the daemon's loopback server could reach and 9 in the Windows board exe; `govulncheck` now reports no reachable vulnerability in any of the three (the one advisory still listed at module level for the daemon, GO-2026-5932, is the unmaintained `x/crypto/openpgp` package, which has no fix and which the daemon does not link). `scripts/release-daemon.sh` sets each build's toolchain explicitly and checks every built binary with `go version -m` before publishing. `golang.org/x/crypto` is v0.58.0, which clears the 13 Dependabot alerts (the daemon never called that code). Because a pin lives in the source folder, the fix ships as new releases; v0.3.0's manifest keeps pointing at its own assets (`t-7efe`).

## [0.3.0] - 2026-10-08

The first tagged release. The highlights since canon became installable on Windows; earlier history is not itemised.

### Added
- `canon update --to <vX.Y.Z|main>` pins an install to a release, or returns it to main (`t-30fc`).
- `--json` on `tkt ls`, `tkt show` and `sprint status`, with the shapes in `tools/ticket.md` (`t-262a`).
- One-line Windows install and the same `canon` command in PowerShell, cmd and Git Bash (`t-8716`, `t-03a8`).
- `canon wait`, to block until a session needs you or is done (`t-d9e6`), and `canon uninstall` (`t-3897`).
- Cockpit: two projects side by side or stacked (`t-416c`), and a keyboard prefix (`ctrl+.` by default) with a `?` cheat sheet (`t-a198`).
- Projects that are not git repositories can be registered; canon keeps its own record of what the agent changed (`t-d538`).
- The cockpit daemon, the Windows board and the headless helper are checksum-verified release assets fetched on install and update, not committed binaries (`t-9383`).

### Changed
- `sprint complete` refuses a close when tracked files changed after the evaluator graded (`t-1b74`), and rejects a reviewer report that lists no per-concern line (`t-de16`).

### Fixed
- Windows: a worktree's tickets landed under the worktree instead of the project's `.tickets/`, and the stale-evaluation check never matched there (`t-7301`).
