# Changelog

All notable changes to canon are listed here, newest first, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

**Versioning.** The number in `VERSION` is [SemVer](https://semver.org): a patch for fixes, a minor for new features that keep working as before, a major for a change that breaks a tool's command line or the install layout. A release is a `VERSION` bump, a dated section below, and an annotated tag `vX.Y.Z` on the public repo, made by `scripts/release.sh` (see `docs/releasing.md`). Commits between releases are listed under Unreleased. To stay on a release, or go back to one: `canon update --to vX.Y.Z`.

## [Unreleased]

### Added
- `tkt merge-pr` shows progress while the tests run: one line rewritten in place on a terminal (elapsed time and the newest line of the test output), a plain line every 30 s otherwise (`CANON_PROGRESS_SECONDS`). Ctrl-C stops the whole test run. `tkt merge-pr <id> --check` runs only the checks that execute nothing, prints what it would do, and stops: the board's Check & merge dialog will use it (`t-bad4`).

### Changed
- Claude cloud sessions: the issue `tkt send-issue` writes asks the session to plan in `plan.md` rather than in Claude Code's plan mode, which was observed to stop the close gates. `docs/setup.md` says how to start and approve a cloud session and how to finish one on your machine when it cannot close there; `tkt merge-pr` then also deletes the leftover `canon-results/<id>` branch (`t-b2e5`).

## [0.12.0] - 2026-10-16

The GitHub workflow runs end to end from the command line: issues become tickets (`tkt sync-issues`) or tickets become issues (`tkt send-issue`), a Claude cloud session works them, `tkt import-results` brings the results back and `tkt merge-pr` checks and merges the PR. Update with `canon update`. No daemon change: nothing to restart.

### Changed
- `docs/setup.md` › Claude cloud sessions: the environment's setup script also installs the Go toolchain canon pins (read from the installed release; network hosts listed) and copies canon's reviewer and evaluator agents, so a cloud sprint can run its close gates and the full suite.

### Added
- `tkt sync-issues [--dry-run]`: each open issue on your `origin` GitHub repo labelled `canon` that no ticket links to becomes a ticket (type and priority from labels such as `bug` and `p1`; a body in the send-issue layout keeps its Acceptance and Plan). It only reads GitHub, and skips pull requests and issues `tkt send-issue` made. The label is what admits an issue, so keep it for issues you have read: anyone who can open issues may get it from an issue template, and an author can still edit the text after it is labelled. Run `--dry-run` first (`t-4cd8`).

- `tkt merge-pr <id> [--pr N] [--test CMD] [--yes]` finishes a cloud ticket on your machine: it finds the PR that says `Fixes #<issue>`, checks the evaluator passed on that PR's exact head and GitHub can merge it cleanly (a fork's PR is refused: the next step runs its code), asks once, since your tests are the PR's code (`--test`, else `scripts/test.sh`), then runs them on base + PR in a scratch clone and merges only if they pass with `--match-head-commit` and records `merged:` in the ticket. Your working tree and local branches are not touched (`t-4718`).

### Fixed
- `tkt import-results` stopped without a message when the imported ticket had no `eval-report.md` (`t-4718`).
- `tkt send-issue` lost every section of a ticket whose files have Windows (CRLF) line endings, and warned that it had no acceptance criteria (`t-c131`, fixed in a Claude cloud session from issue #19).

## [0.11.2] - 2026-10-16

Send to GitHub works end to end: the first send from a Mac, a Claude cloud session reading its issue, and canon's tools run through a symlink. Update with `canon update`. No daemon change: nothing to restart.

### Fixed
- `tkt send-issue`: the first send to a repo from a Mac failed with `labels[@]: unbound variable` and created no issue. GitHub's label search does not list a label created a second earlier, and macOS's bash 3.2 rejects the empty label list that followed. A label that was just created is now used directly, and a send with no label works on any bash (`t-1465`).
- `tkt send-issue`: GitHub hid `<this issue number>` in the issue's "Fixes #…" line as an HTML tag; it is now in a code span (`t-1465`).
- In a Claude cloud session, `sprint import-issue N` failed with a 403 and needed `--body-file`: the session's GitHub proxy refuses GraphQL, which `gh issue view` uses. It now reads the issue over REST (`gh api`), drops the CR characters an issue edited on github.com can carry, and `tkt export`'s public-repo check asks REST too (`t-35d2`).
- `sprint`, `tkt` and seven other tools (`evidence.sh`, `gate-snapshot.sh`, `subagent-log.sh`, `sprint-headless`, `sprint-headless-eval`, `upkeep-run`, `mutant-sweep`) failed when run through a symlink, such as one in `/usr/local/bin` or `~/bin`: they looked for their helper files beside the link. They now follow the link like `canon` does. The Claude cloud environment recipe in `docs/setup.md` uses wrapper scripts, which work on every release (`t-2785`).
- `scripts/release.sh` (maintainers): a CHANGELOG larger than a pipe buffer made the release refuse with "no dated section", because the lookup piped the file into an `awk` that stops early; `awk` now reads the file itself (`t-fef7`).

## [0.11.1] - 2026-10-16

Code blocks in tickets now survive `tkt show` and `tkt send-issue`. Update with `canon update`. No daemon change: nothing to restart.

### Fixed
- `tkt show` (and `show --json`'s `body`, which `sprint status --json` embeds) dropped every description line starting with `# ` or made of `---`, not just the title: a shell comment in a code block or a Markdown rule vanished. Only the title line is dropped now (`t-8543`).
- `tkt send-issue` dropped `<!--` lines inside a code block and split a section at a `## ` line inside one; code blocks now reach the issue as written (`t-8543`).

## [0.11.0] - 2026-10-15

Send to GitHub: hand a ticket to a Claude cloud session as a GitHub issue and bring its results back. Update with `canon update`. No daemon change: nothing to restart.

### Added
- The cloud round trip: in the session, `sprint import-issue N` rebuilds the ticket from a `tkt send-issue` issue and starts its sprint; at the close `tkt export <id>` sends the ticket back (inside the PR when `.tickets/` is committed, otherwise on a `canon-results/<id>` branch); `tkt import-results <id> --pr N` brings it back on your machine, keeping any local edit in `.before-import/` and checking the evaluator graded the PR's head. `tkt send-issue` now keeps `# ` lines inside a ticket's code blocks (`t-554c`).
- `tkt send-issue <id>` posts a ticket as an issue on your `origin` GitHub repo, laid out like the ticket on the board (Description, Acceptance, Plan and Research, each with every section the board lists), for a Claude cloud session to work on: type `Work on Issue#N` in a session on a "canon" environment. `--dry-run` previews it; a public repo needs `--public`; it records `github: owner/repo#N` in `ticket.md`. `docs/setup.md` › Claude cloud sessions has the one-time environment recipe (`t-a059`).

### Fixed
- `skills.sh add` no longer writes the canon install's absolute path into your project's `AGENTS.md` (the Active canon skills table and its note). Rows now name the skill relative to the install (`skills/sprint/SKILL.md`), so a clone on another machine, a teammate's or a Claude cloud session's, no longer comes out with `AGENTS.md` modified. Existing projects are rewritten once on the next `canon update` (`t-97e2`).

## [0.10.0] - 2026-10-15

Update with `canon update`. No daemon change: nothing to restart.

### Added
- `tkt compact [--older-than DAYS] [--dry-run]` shrinks `.tickets/`, which every board-spec run and scratch copy duplicates: for closed or cancelled tickets older than 14 days it deletes the raw board-spec JSON reports and packs the rest of `evidence/` into `evidence.tgz` (restore: `tar -xzf .tickets/<id>/evidence.tgz -C .tickets/<id>`). Evidence cited by path, folder or wildcard pattern stays loose. `sprint complete` runs it after every close; a compact failure only warns (`t-2fb6`).

### Changed
- `standards/efficiency.md`, loaded on every turn in every project with canon's standards, is cut from 2,444 to about 690 words: it keeps the rules nearly every session needs, and the domain rules (shell strict mode, tests and guards, security checks, destructive commands, renames, cross-backend parity, Windows / Git Bash, Go tests…) move verbatim to the on-demand `standards/efficiency-notes.md`, named by one index line. `standards/skill-setup-std.md` gains `## Where a lesson goes`, which `promote-learnings` follows (`t-8837`).
- `tests/run-board-spec.sh` records the machine's load at the start and end of every run (`$OUT/machine-load.txt`) and warns when another board spec or `test.sh` run is going or the load exceeds the CPU count: WebKit fails timing-sensitive tests under contention, so such failures are rerun before they are trusted (`t-5989`).
- `mutant-sweep` checks for a working Python 3 first (`python3`, else `python` when it is Python 3): with none (missing, Windows' Store alias, Python 2) it exits 3 with `skipped — no working python3` instead of a shebang error, and `sprint complete` records `mutation-test | skipped | no python3` without reading the skill. `mutant-sweep --check` runs just that probe (`t-a5f6`).
- Wrapup's `repo-check` gate runs only in a canon checkout: in your own project it is recorded `skipped | not a canon checkout` without being read, since it checks canon's own surface (skill graph, catalog, the board). Its two checks that apply anywhere moved: `doc-audit` now checks that every path, command and script a changed doc names still exists, and `code-reviewer` runs `bash -n` / `py_compile` on changed files (`t-b215`).

## [0.9.1] - 2026-10-15

Cockpit and board fixes for light themes and Safari, and faster, stricter sprint tooling for whoever builds canon: parallel test runs, generated mutant sweeps, and one-page sprint checklists.

No daemon change: after `canon update`, reload the board and Cockpit pages; no restart needed.

### Fixed
- Cockpit, light themes: dim labels (`--text-dim`) were unreadable (about 1.6-1.8:1 contrast); they now read as text (`t-38f1`).
- Board, light themes: the Upkeep button's text was unreadable on hover (`t-4064`).
- Cockpit, Add Project in Safari: the "Show hidden" checkbox rendered 0 px wide (`t-b5c7`).

### Added
- `tests/run-board-spec.sh --classify [--solo-runs N] [--base REF]`: reruns each failure that is not in the baseline alone, on the copy and on a copy of REF, and prints a paste-ready baseline entry only for a load timeout that passed every solo run on both (`t-b860`).
- `mutant-sweep` (`tools/mutant-sweep`): generates mutants over a sprint's changed shell and JS lines from one fixed operator table (comparison, boolean and off-by-one flips, negation, return/exit codes, sort/unique, dropped `&&`/`||` operand, dropped regex anchor, widened pattern, emptied string, line deletion), runs each mutant's covering test in a throwaway copy, and lists the survivors; a timeout or Ctrl-C stops the test's whole process group and removes every temp folder. The `mutation-test` skill now runs it at `sprint complete` step 1, before the reviewer and evaluator, and triages every survivor (`t-1fac`).
- `sprint check-evidence <id>`: before the evaluator is dispatched, it checks that every stamped evidence log is fresh at HEAD with exit 0, and names each one to re-stamp or fix, so a stale or failing log no longer costs a failed evaluator run (`t-a3d7`).

### Changed
- Sprint start and close read a one-page checklist first (`skills/sprint/reference/start-checklist.md`, `complete-checklist.md`) and open `start.md` / `complete.md` only for a case the checklist names (bugfix, demo, high-risk, Copilot/Codex/pi, a failed gate…): a normal sprint reads about 1,600 words instead of 14,000.
- `scripts/test.sh` prints each suite's time, the 10 slowest and the total, even when a suite fails; `--list` prints every suite it runs, and `scripts/test-hermetic.sh` now reads that list instead of parsing test.sh (`t-2633`).
- `tools/skill-eval-scope.sh` skips a skill whose only changes are docs outside its `SKILL.md` (reference/, gates/, the gate agents) that no eval case names, since an eval executor is given `SKILL.md` alone; a change to the skill's `evals/evals.json` now counts as a reason to run (`t-a1b1`).
- `scripts/test.sh` runs its suites in parallel (`--jobs N`, default the CPU count up to 8): a full run took 212-235 s instead of 802 s on a 10-CPU Mac, still runs every suite, keeps each suite's output under its header in list order, and exits with the first failing suite's code. `--jobs 1` runs them one at a time and stops at the first failure, as before; suites that share state with another run alone after the batch (`t-abb1`).
- `evidence.sh check` keeps a log fresh when only close-time docs changed since (`LEARNINGS`, `DECISIONS`, `HANDOFF.md`, `PROMOTED.md`, the subagent log), and counts a full board-spec run as `covered` when only the baseline changed and a stamped guard run re-judged the same reports (`t-a3d7`).
- `scripts/test.sh`'s leaked-server check fails only on a board server that run started and left running (it carries the run's `CANON_TEST_RUN`), so your own board or a board spec running alongside no longer fails a test run, and a leaked server whose parent is still running no longer passes it.
- The Themes page (`THEMES.md`) opens with the default themes and a screenshot of the ◐ Theme menu (`t-d695`).

## [0.9.0] - 2026-10-14

Themes for the Cockpit: a ◐ Theme switcher, six built-in themes, and your own themes from theme files.

### Changed
- Cockpit: **◐ Theme** replaces the sidebar's Dark/Light button. It opens a small panel with Mode (System, Light or Dark; System follows your computer) and the theme for that mode, one pick for light and one for dark under System; hover the button to see the theme in use. Canon Dark and Canon Light look as before (`t-2758`).
- Cockpit: six more themes, Catppuccin Mocha and Latte, Tokyo Night, Nord, Dracula and Gruvbox Dark, each from its project's own palette and readable at WCAG AA; hover a theme to preview it, click to keep it. The shell and every open board follow, from the first frame. Credits and licences are in `THEMES.md` (`t-4fa5`). The terminal stays dark for now (`t-2ba3`).
- Cockpit: your own themes. Drop a theme file (a name, a mode and 12 hex colours) in `~/.canon/themes/` and it appears in ◐ Theme under its mode; **Open themes folder** creates the folder with an example. Files are checked by the board and again in the page; a refused file is listed with the reason, and a hard-to-read theme is marked Low contrast. Format and rules: `docs/custom-themes.md` (`t-f889`).

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
