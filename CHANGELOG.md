# Changelog

All notable changes to canon are listed here, newest first, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

**Versioning.** The number in `VERSION` is [SemVer](https://semver.org): a patch for fixes, a minor for new features that keep working as before, a major for a change that breaks a tool's command line or the install layout. A release is a `VERSION` bump, a dated section below, and an annotated tag `vX.Y.Z` on the public repo, made by `scripts/release.sh` (see `docs/releasing.md`). Commits between releases are listed under Unreleased. To stay on a release, or go back to one: `canon update --to vX.Y.Z`.

## [Unreleased]

### Changed
- `canon stop`, `canon restart`, the not-running messages and the "already running" line use one plain style, with no em-dash joins: "Stopped the Cockpit: the board and the daemon have exited.", "The Cockpit is not running on port 8899. Nothing to stop." / "Start it with: canon", "Stopped the daemon. The board had already exited.", "Restarted the daemon.". `canon wait`'s timeout line, `canon status`/`canon sessions` when the Cockpit is not running, and the "board does not support" line follow the same style. Exit codes are unchanged. The board's own start banner (`Canon Cockpit X listening on ...`) is left as is, since rewording it would need a new canon-go release (t-9a2d).

### Fixed
- On Windows, `canon uninstall`, `canon stop` and the update guard now find the Cockpit daemon: it records itself in `%LOCALAPPDATA%\canon-cockpit`, a folder the scripts did not look in, so uninstall reported the daemon as an unknown `canon-go-win.exe` and refused (t-4872). Until you have this release, run `canon stop` before `canon uninstall`.

## [0.30.2] - 2026-10-29

Update with `canon update` (stop the Cockpit first). **Restart the Cockpit daemon after updating** (Admin > **Restart Daemon**): the terminal's files are built into the daemon, so a daemon started before the update keeps the old terminal.

### Changed
- Close-gate reports, the Wrapup Gates rows and the gate-run log name the model with its id, e.g. `sonnet (claude-sonnet-5-5)`, not only the alias the dispatch passes, so a later remap of `sonnet` stays visible (t-7299).
- **The Cockpit terminal runs on xterm.js 6** (t-d689): `@xterm/xterm` 6.0.0 and `@xterm/addon-fit` 0.11.0 replace the deprecated `xterm` 5.3.0 and `xterm-addon-fit` 0.8.0, which get no more fixes. It brings upstream fixes for IME input, screen-reader selection, a memory leak and a new scrollbar. The keys send what they sent before: Option/Alt+Left/Right (word jump), Alt+Up/Down on Windows and Linux, and Ctrl+Backspace (DEL, not 6.0's ^H). The hand check on Windows (ConPTY, IME) and Linux is t-f04d; to go back, see `docs/ci-security.md` (Rolling back).

### Removed
- `tools/llm-call`, an unused single-shot LLM adapter (nothing in canon called it). The release zip also leaves out two developer-only files, `tools/vendored.tsv` and `tools/sprint-check-app/CLAUDE.md` (t-7299).

## [0.30.1] - 2026-10-29

Update with `canon update` (stop the Cockpit first), then restart the daemon (Admin's **Restart Daemon**): the board changed.

### Fixed
- **`canon uninstall --keep-data` in the versioned layout keeps all your data** (t-cb66): every data entry of the home (`cockpit/`, `events/`, `themes/`, `settings.json`, `integrity/`, `logs/`, `.canon-track`, `.canon-cache`), not only `cockpit/`; only `packages/`, `current`, the `tools` link and the lock files go. A plain `canon uninstall` still removes the whole home.
- `canon uninstall` in a home other than `~/.canon` with `CANON_HOME` unset now reads that home's data (its Cockpit registry, its `cockpit/`), not `~/.canon`'s.
- `canon uninstall` keeps the home, naming what it found, when `packages/` holds a `.tmp-migrate.*` folder (it may hold your files) or an entry canon did not put there, and takes the update lock, so it refuses while `canon update` runs.
- The integrity check (Admin > Integrity, and `sprint complete`'s gate) reads `.canon-track` from the home in the versioned layout, so `packages/main` shows as the main track instead of "not exactly at vX".

## [0.30.0] - 2026-10-29

**Restart the Cockpit daemon after updating** (Admin > **Restart Daemon**, or `canon stop` then `canon`): a daemon started before the update keeps running the old program, and the Cockpit shows it as out of date until it restarts.

### Changed
- **The board and the Cockpit daemon are one program, `canon-go`** (t-bdb0). Its first word picks the mode: `canon-go board [<port>]` (or no word) is the board, `canon-go daemon` the daemon, `canon-go --version` prints the build. It lives at `tools/canon-go-bin/canon-go` on macOS/Linux and `tools/canon-go-win.exe` on Windows, replacing `tools/cockpit-daemon/cockpit-daemon`, `tools/sprint-check-bin/sprint-check`, `tools/cockpit-daemon-win.exe` and `tools/sprint-check-win.exe`, which `canon update` removes once `canon-go` is in place. A Windows install is about 7 MB smaller, and each update fetches and verifies one file instead of two.
- The Cockpit's "out of date" banner now compares the daemon's source key, built into the program, instead of the file's time, so a board-only release no longer asks you to restart an unchanged daemon.
- Release assets are `canon-go-<os>-<arch>` (and `canon-go-windows-amd64.exe`) in one `canon-go-<key>` release; older installs keep fetching the `cockpit-daemon-*` and `sprint-check-*` assets their own manifest names.

### Known
- On Windows, stop the Cockpit before `canon update` (Admin > **Stop**, or `canon stop`): the one program is now both the board and the daemon, so while either runs Windows locks the file and the update keeps the old program (it says so).

## [0.29.0] - 2026-10-29

macOS and Linux only; Windows installs are unchanged (t-05c9). Update with `canon update`. No daemon restart is needed, but **stop the Cockpit first**: from this release `canon update` refuses while this install's Cockpit daemon or board runs, and never stops or restarts it for you (Admin > **Stop**, or `canon stop`).

### Changed
- **A release install is now a versioned package.** `~/.canon` holds `packages/<vX.Y.Z>/` (the release, no `.git`), a `current` link to the one in use, and your data beside them (`cockpit/`, `events/`, `themes/`, `settings.json`, `integrity/`). An update installs the new package, then switches `current` in one step, so a failed or interrupted update leaves the old version running. The two newest older releases are kept, and `canon update --to vX.Y.Z` of one of those switches back with no download. `canon update --to main` installs a clone in `packages/main`.
- **The first update of an older install moves it into this layout.** The clone becomes `packages/<tag or main>`, your data stays where it is, and `~/.canon/tools` stays as a link so existing PATH lines keep working. Project links, imports, git hooks, `~/.config/canon/install_path` and the PATH line are rewritten to name `current`, so later updates never touch them again. A migration that fails or is interrupted puts everything back.
- `canon uninstall` knows the new layout, and it keeps the home (and says so) when it holds files that are not canon's. A clone detached on a release tag no longer blocks it.

### Fixed
- A fresh install no longer fails when `CANON_HOME` is reached through a symlink (a dotfiles-managed `~/.canon`).

### Known
- Local, gitignored files inside an old clone (for example `.tickets/` of a developer checkout) move with it into `packages/`, and pruning an old release package deletes its folder. Keep your own files in the home, not in a package.
- An install that holds a `settings.json` cannot update with its old updater (it sees a changed tree and refuses). Move the file aside once, then put it back:
  `mv ~/.canon/settings.json ~/.canon/settings.json.bak && canon update && mv ~/.canon/settings.json.bak ~/.canon/settings.json`
- A kill (SIGKILL) in the middle of the migration can leave your files in `~/.canon/packages/.tmp-migrate.*`; they are not deleted, so move them back by hand.

## [0.28.2] - 2026-10-29

Update with `canon update`, then restart the daemon (Admin's **Restart Daemon**): the board's Integrity check lists one more gate file.

### Changed
- A normal sprint loads about 7k fewer tokens. The sprint skill and its close checklist drop a stale note and repeated wording, and the reviewer and evaluator gates no longer read the generic subagent-report guide or the browser-render detail unless a UI change is being rendered (that detail now lives in `reference/visual-verify.md`). Every rule a gate follows stays, and a fixed set of four known-verdict changes grades the same before and after.
- The close checklist no longer tells a user project to run canon's own `scripts/test.sh` or release steps.

### Added
- The sprint skill's evals cover the light close, the bugfix tier and skills-path lookup.

## [0.28.1] - 2026-10-28

Update with `canon update`. No daemon restart is needed.

### Fixed
- A cloud session that cannot finish its close now still comes back. The issue's steps tell it to run `tkt export <id>` anyway and to say in the PR which step failed and why. When nothing came back (an open PR, no results to import), the ticket's card offers **Close here**: it makes a worktree at the PR head (`tkt land`) after a confirm that says to use it only once the cloud session has stopped. `tkt import-results` names the same next step (`tkt land <id> --pr N`) when the PR carries no ticket.
- canon's own test suite can now pass in a Claude cloud session, which runs as root: the four terminal tests that need an OS password prompt skip there (canon correctly finds none for root), and the folder-guard test checks a system folder only where it exists (`/private/etc` is macOS-only).

### Changed
- `mutant-sweep` leaves out two kinds of low-value shell mutants: emptying a double-quoted string that is only variables (`"$root"`, `"$a/$b"`), and anything but line deletion on a line that only prints (`echo`/`printf`). The report says how many it left out (`skipped by rule: N`). On a large change of `tools/tkt` this cut the mutants from 343 to 241, so a close's sweep runs about 30% faster.

## [0.28.0] - 2026-10-28

Update with `canon update`, then restart the daemon (Admin's **Restart Daemon**): the board has new routes.

### Added
- **Commit and push…** in the Send to GitHub panel. When the send is refused for commits origin does not have, or warns about uncommitted files, the panel lists the changed files (new, untracked files unticked: one could be a secret), takes a commit message, and after a confirm that names the files and the branch commits exactly those files and pushes the branch to origin. Never forced; a branch origin does not have yet is pushed with `-u`; refused when origin has commits you lack (pull first). The send preview then runs again. From a terminal: `tkt commit-push <id> [--dry-run] [--file <path>]... [--message <text>]` (in the Cockpit Terminal it needs `su`, like `push-main`). New: `GET /api/ticket/<id>/github/commit-push-preview` and `POST /api/ticket/<id>/github/commit-push`, both refusing a cross-site Origin.

### Changed
- Factory › GitHub › Cloud environment starts with **Give Claude this repository** (install the Claude GitHub App on it: a private repository is invisible to cloud sessions without it) and ends with **Start a new session** after you change the setup script. The Checks count now reads "ready on this machine", since canon cannot see your cloud setup. The Sent panel names the same prerequisites, and `docs/setup.md` says both.

## [0.27.2] - 2026-10-28

Update with `canon update`. No daemon restart is needed.

### Fixed
- After **Check & merge** (or `tkt merge-pr`), your local main now catches up by itself in a project that commits `.tickets/`. Before, the files `tkt import-results` had written (the ticket's files, `.before-import/` copies, `.claude/subagent-runs.jsonl`) made every `git pull` fail with "would be overwritten by merge", and the Merged dialog did not say why. `merge-pr` now sets aside each file that is identical to the merged copy, the ticket's `ticket.md` when it differs only in canon's local fields (`github:`, `runs:`, `merged:`, `cloud_status:`, kept as they were), and the audit log (your local lines are appended after the merged ones), fast-forwards, and puts them back. Any other file that differs, or a staged one, leaves main where it was, and the output and the Merged dialog name each file and the `git pull` to run (in the Cockpit Terminal, type `su` first). It is still only ever a fast-forward. PR paths are untrusted: they are matched literally and never followed through a symlinked folder.
- `.tickets/<id>/.before-import/` (the copies `tkt import-results` keeps) is now in the `.tickets/.gitignore` canon creates (added to one canon created earlier; your own file is left alone), and `tkt export` never sends it.
- A cloud session's closing message now gives commands that run as written: `tkt import-results <id> --pr <N>`, then `tkt merge-pr <id>`.
- An import whose PR head is not the graded commit now shows on the ticket's GitHub tab as `import refused`, not `imported`.

## [0.27.1] - 2026-10-28

Update with `canon update`. No daemon restart is needed.

### Fixed
- A cloud sprint's run no longer needs a re-grade on the Mac for its audit log. A cloud session commits `.claude/subagent-runs.jsonl` after its evaluator graded, so `tkt merge-pr` and the card's Check & merge treated every clean cloud run as new code. `merge-pr`, `tkt import-results` and the card now accept lines **added** to that log (a changed, removed or binary log, a symlink, and every other file under `.claude/` still need a re-grade). `docs/setup.md` › Who grades what says why.
- When the cloud closed a ticket but its PR head differs from the graded head, the import dialog, `tkt import-results` and `tkt land` now name `tkt land <id> --pr N --fix`. Before, three messages sent you in a circle: the dialog said to use `land`, `land` refused a closed ticket and said to import first, and the import failed again.

## [0.27.0] - 2026-10-28

Update with `canon update`, then restart the daemon (Admin's **Restart Daemon**): the board has new routes.

### Added
- **Admin › Logging** (the Cockpit): what canon keeps and where (the real folder), **Keep for** (30 days by default, 90 days, 1 year; a shorter choice asks first and says how many days will go), **Compress files older than 7 days**, **Show in folder**, **Export .jsonl**, **Verify**, and **Delete…** (after a confirm; the new log starts with a `log.deleted` note). The log stays always on; Verbose session logging is on the same page. Settings are saved to `~/.canon/settings.json` and each change writes a `setting.changed` event. New: `GET /api/admin/logging` (with `/verify` and `/export`) and `POST /api/admin/logging` (with `/delete` and `/reveal`); every write needs a loopback `Origin`.
- `docs/setup.md` says what canon keeps on your computer and how to delete it.

### Changed
- Factory's Intake card says "none in the last 30 days" (the retention setting) instead of "never" when the log holds no sync.

## [0.26.0] - 2026-10-28

Update with `canon update`, then restart the daemon (Admin's **Restart Daemon**): the daemon now maintains the activity log.

### Added
- **Day seals and `canon log verify`.** The activity log (`~/.canon/events`) gets one seal per closed day in `seals.jsonl` (the day's line count and SHA-256, chained to the previous seal). `canon log verify` prints `intact`, `broken`, `missing` or `unsealed` for each day and exits 1 when a day was changed, deleted or reordered; `canon log seal` seals what is due. The daemon seals hourly, and so does the first event of each day. A seal shows a day was not changed after it was sealed; it does not show who wrote it.
- **Keep for is a setting.** `log.retention_days` in `~/.canon/settings.json` (30, 90 or 365). Sealed days older than 7 days are gzipped, and each removal writes a `log.pruned` event.

### Changed
- **The activity log is now kept for 30 days, not 90.** The first event written after you update, or the daemon at its next start, removes every day file older than 30 days (and records it). To keep more, set `{"log":{"retention_days":90}}` in `~/.canon/settings.json` before updating. Your first event files date from 2026-10-20, so nothing is that old until about 2026-11-19.

## [0.25.1] - 2026-10-28

Update with `canon update`. No daemon restart is needed.

### Fixed
- A project that commits `.tickets/` has no `canon-results/<id>` branch, so a ticket sent to a cloud session could not be brought back. `tkt import-results` now reads the closed ticket from the pull request's head, and `tkt github-status` reports it as results-ready. A pull request from a fork is refused, and a `gh` failure is reported with its reason instead of looking like "no results".
- The Claude cloud environment text says "Network access: Limited" with the domains added and Allow package managers ticked, and `cloud-env.sh` installs from `https://getcanon.dev/install.sh`.

## [0.25.0] - 2026-10-28

Update with `canon update`, then restart the daemon (Admin's **Restart Daemon**): the Terminal in the daemon changed.

### Added
- A project settings file: `.canon/settings.json` (shared with the team) and `.canon/settings.local.json` (yours; the board keeps it out of `git status` through the repository's own `.git/info/exclude`). The first key is `terminal.paging` (`auto`, `off`, or 5 to 500 lines). The file is read with size, depth and symlink limits, a bad file is reported by name and never overwritten, and the board writes only the local file, atomically, with mode 0600. See `docs/sprint-check.md` › Project settings.
- A **Paging** control on the Terminal's rail card, and a `paging` command in the Terminal (`paging off`, `paging auto`, `paging 20`) that changes the setting for that Terminal only. A Terminal reads the setting when it starts.
- `/api/settings` (GET, and POST for a loopback Origin) and a `setting.changed` event for each project setting saved.

### Fixed
- The source keys of the daemon and the board now list every package they are built from (`internal/term`, `internal/settings`), and `tests/src-key.sh` checks them against `go list -deps`, so a change to those packages re-keys the binary.

## [0.24.0] - 2026-10-27

Update with `canon update`, then restart the daemon (Admin's **Restart Daemon**): the daemon's event writer changed.

### Added
- The event log now records the actions that change things, as lines in `$CANON_HOME/events/YYYY-MM-DD.jsonl` (the file `docs/plugins.md` describes):
  - `close.confirmed` when `sprint complete` closes a ticket, with the plan's tier when its Sign-off names one;
  - `github.sent`, `github.results_imported` (a clean import) and `github.merged`, from `tkt send-issue`, `tkt import-results` and `tkt merge-pr`;
  - `setting.changed` when the Admin Model tiers page saves, applies, retires or removes (the Review & Eval default model before and after, never a source URL) and when the Verbose session logging switch changes.
  A command run from a terminal carries no `actor`, because it cannot tell a person from an agent; a Model tiers write from the Admin page carries `actor: user` only when it comes with a loopback Origin. Nothing in the app shows these lines yet: read them with any tool that reads JSON lines. `docs/plugins.md` also lists the kinds that are not written yet and why.

### Fixed
- A test of the board's Check & merge shutdown could fail under load; it now waits for the stub it signals instead of sleeping.

## [0.23.0] - 2026-10-27

Update with `canon update`, then restart the daemon (Admin's **Restart Daemon**): the event writer in the daemon changed.

### Added
- A ticket you planned here (in progress, nothing working on it) can be sent to a Claude cloud session: the Cockpit's **GitHub · new issue** option now shows for it, and `tkt send-issue` accepts it. As it leaves it goes back to `open`, like any sent ticket.
- `tkt send-issue` (and its `--dry-run`, which the board's preview runs) now checks what GitHub can see, in the ticket's own worktree: commits that are on no branch of `origin` are refused, because the cloud session works from GitHub (push first, or add `--allow-unpushed` in a terminal), and uncommitted or untracked changes get a warning. Open tickets get the same checks.
- Events gain an optional `actor` field (`user`, `agent` or `system`: who caused the event, as opposed to `source`, the program that wrote it). Nothing sets it yet; older events simply lack it. `kind` and `source` are unchanged. See `docs/plugins.md`.

### Changed
- A full board-spec stamp now runs one pass per browser and repeats (up to 3) only for a browser whose first report the guard rejects: about 33 minutes instead of about 98. `--runs N` is still exactly N.

## [0.22.2] - 2026-10-27

Update with `canon update`. No daemon restart is needed: only a Cockpit board page changed.

### Fixed
- The board search with a list of ticket ids no longer shows nothing when one id does not exist. `t-43a2 t-1212` now shows `t-43a2`, and the count line says `1 of N · ignored t-1212`. This applies when every term is written as a full id (`t-` and four characters); bare terms and ordinary words such as `to do` search as before.

## [0.22.1] - 2026-10-27

Update with `canon update`. No daemon restart is needed: only the Cockpit pages and a gate doc changed.

### Changed
- In the Cockpit, `Ctrl+.` then `P` then `f` / `l` go to the first / last session tab of the project (they used to land on the Board), and the new `P h` goes Home to the project's Board. `P n` / `P b` are unchanged. The shortcuts sheet and key hint list them.
- The "More than one agent is working in this folder" banner stays dismissed once you close it: for that project, in that browser, also after the sharing restarts or the page reloads.

### Fixed
- A prefix action the Cockpit does not know no longer jumps to the last tab.
- Gate renders (the reviewer's and evaluator's headless Chrome check) no longer use your real Chrome profile or the macOS keychain, so they cannot raise a "Keychain Not Found" dialog on your desktop. The recipe is in `skills/sprint/reference/shared-gate-protocol.md`; projects get it with `canon update`.

## [0.22.0] - 2026-10-27

The Cockpit's Agents list keeps the order the agents were opened in, and a short bar in the theme colour marks the agent you are in. Update with `canon update`, then restart the daemon (Admin's **Restart Daemon**): the daemon program changed, and a running one stays on the old order until restarted.

### Added
- A short vertical bar, in the theme's accent colour, at the left of the Agents row of the session you have open, including a scratch session that has not started yet. Admin, Factory, Projects and the Board alone show none.

### Fixed
- The Agents list no longer moves around. It follows the order the agents were opened; a project's group keeps its place while the page is open, and a failed refresh does not forget it.

## [0.21.4] - 2026-10-27

Shift+Enter inserts a newline in a Cockpit agent session. Update with `canon update`, then restart the daemon (Admin's **Restart Daemon**): the daemon program changed, and a running one stays on the old page until it restarts.

### Fixed
- **Shift+Enter inserts a newline in Claude, pi and copilot sessions** (`t-6aaf`): the terminal sent the same Enter for Shift+Enter, so an agent could not tell them apart and submitted. An unmodified Shift+Enter now sends ESC then Enter, the newline sequence agents accept. The restricted Terminal, Ctrl+Enter and the other keys are unchanged, and the Ctrl+. prefix keys work as before. Until you restart the daemon, use Ctrl+J, or a backslash then Enter.

## [0.21.3] - 2026-10-27

Check & merge can no longer be stopped by the terminal the board was started from, and quitting the board ends a running merge. Update with `canon update`, then restart the board (the board program changed; the daemon did not).

### Fixed
- **Check & merge no longer hangs on the board's own terminal** (`t-ada9`): the merge job inherited the terminal the board was started from, so any step under it that opened `/dev/tty` (git, ssh, sudo) could stop the whole run, as one did for 25 minutes. The job now runs in its own session with no terminal.
- **Quitting the board ends a running merge** (`t-ada9`): a Ctrl-C or SIGTERM to the board stops its merge jobs (the tests are ended and nothing is merged), waits up to 4 seconds, then exits.

## [0.21.2] - 2026-10-27

The board's agent-starting routes now refuse a request with no Origin header. Update with `canon update`, then restart the board (the board program changed; the daemon did not).

### Security
- The board routes that start an agent (`POST /api/skill-eval/run`, `POST /api/ticket/<id>/headless-run`) now refuse a request with no loopback `Origin` header, and the headless run needs `confirm: true` (t-d42a). The Cockpit daemon's `/session/start` (a session you start, gated by the boot token) is unchanged.

## [0.21.1] - 2026-10-27

Send to GitHub stays reachable next to a Terminal, and a Terminal placed beside a tab is no longer a short strip. Update with `canon update`, then reload the board (no daemon or board-program change).

### Fixed
- **Create issue is no longer hidden behind a split Terminal** (`t-3d04`): with the Terminal below or beside a ticket's Send to GitHub panel, the panel took the whole area and the Terminal covered its lower half and its scroll bar. It now takes only its own pane's share and follows the divider.
- **A Terminal placed beside a tab fills its half** (`t-3d04`): it was 150px tall, so its text and prompt were cut off.
- **To Claude Cloud copies its command on every OS** (`t-3d04`): the `tkt send-issue <id> --launch` line is copied as well as typed in the Terminal, and the status says when the copy was blocked.

## [0.21.0] - 2026-10-26

The board's tickets are soft cards, the Demo/UX badge is now Lite, and the board and the Cockpit shell share one palette file. Update with `canon update`, then restart the board (the board program changed; the daemon did not).

### Changed
- **Soft cards** (`t-be64`): a card is a hairline-bordered, rounded surface with no header band and no coloured left edge, and a soft hover. A column's short vertical bar is the only status colour. The per-column `+` is gone (`+ New` adds a ticket). An In progress card shows its branch on its own line, and an unchecked ticket reads `N to check` (the unchecked boxes of `acceptance.md` and `plan.md`) instead of `unchecked items`.
- **Lite** (`t-be64`): the badge, the Plan switch and the New-ticket option that said Demo/UX now say Lite, in warn-coloured text and outline instead of a solid orange fill. The ticket flag stays `demo: true` and `tkt demo` is unchanged.
- **One palette file** (`t-be64`): `static/tokens.css` defines Canon Dark and Light once for the board and the shell (they had drifted), plus the radius, font, spacing and shadow scales. The dark secondary text (the version next to Canon Cockpit) is now readable, and scrollbar thumbs are quiet until hovered.

### Fixed
- **An editor's lock file no longer shows as a doc tab** (`t-be64`): an Emacs `.#plan.md` or `#plan.md#` in a ticket folder is skipped.

## [0.20.7] - 2026-10-26

The Terminal tab's `×` and End Session end the Terminal, Check & merge understands draft PRs, and a GitHub route can no longer start a merge by accident. Update with `canon update`, then restart the board so it loads the new program.

### Fixed
- **A GitHub route action without a handler can no longer start a merge** (`t-bb1b`): in the board, an action added to the GitHub write routes without its own branch used to fall through to starting a merge run (which runs the PR's tests here and merges). `merge` is now explicit, anything else without a branch is a 404, and a test fails when one is added without its branch. Nothing reachable today changes.

### Added
- **Check & merge knows about drafts** (`t-a463`): a cloud PR is always opened as a draft and GitHub will not merge one, but the 3.5-minute test run came first and the refusal after it was a vague GraphQL error. `tkt merge-pr` and `--check` now stop in seconds with "PR #N is a draft; GitHub will not merge it" before running anything, the card's dialog shows that reason above the log with a **Mark ready** button (`tkt pr-ready <id>`: only the ticket's own open, same-repo draft PR, a `--pr` that is not the ticket's PR is refused, reversible with `gh pr ready --undo`), then checks again. A merge GitHub refuses after a passing suite now says the suite passed and what the PR reads like (draft, behind, blocked).

### Changed
- **A Terminal tab's `×` and End Session end the Terminal** (`t-2aed`): a Terminal starts as soon as it opens, so there is no agent to end; the `×` on its tab (and the End Session button, which was greyed out) now asks "Close this Terminal?" (Enter closes it, `c` cancels), the same as the prefix then `x`. An agent or Scratch tab's `×` is unchanged: it only hides the tab and never ends the session.
- **A cancelled "Close this Terminal?" dialog could answer a later Enter** (`t-2aed`, from `t-57ab`): after cancelling it with the mouse, its key listener stayed armed, so the Enter meant for an agent session's own End Session dialog was taken as "End without saving". The listener now acts only while it is still the Terminal's dialog.

## [0.20.6] - 2026-10-26

Canon starts in your home folder, and the Windows first-run text is right. Update with `canon update`, then restart the board so it loads the new program.

### Changed
- **`canon`, `tkt` and `sprint` start in your home folder** (`t-dec4`): the home folder is a project like any other, with its tickets in `~/.tickets` (macOS, Linux, Windows). A folder under home is its own project: the search stops at home, so home's `.tickets` or `.git` (a dotfiles repository) and anything above home cannot take over the folders beneath it. Drive roots and system folders are still refused.

### Fixed
- **Windows first-run text** (`t-dec4`): the board's start line said `Canon Cockpit dev` on a release install; it now names the installed version. The refusal for a drive root or a system folder showed Git Bash's `/c/Windows/System32` and `mkdir -p`, which PowerShell does not accept; on Windows it now shows `C:\Windows\System32` and `mkdir "C:\Users\you\projects\demo"` (works in PowerShell, cmd and Git Bash).

## [0.20.5] - 2026-10-26

A clean Windows first run works, and the Projects cards stay current. Update with `canon update`, then restart the board so it loads the new program.

### Fixed
- **A stray `~/.tickets` blocked every folder under home on a first run** (`t-5738`): `tkt`, `sprint`, `canon` and the board took the first `.tickets` going up, so a `.tickets` left in the home folder by an earlier install made every folder under home resolve to home, which canon then refused. A `.tickets` in a folder canon refuses as a project (home, a drive root, a system folder) is now skipped. The refusal names an example folder to make (`<home>/projects/demo`), and says how to move old tickets from home into a project (it never moves them). `install.sh` and `install.ps1` end with the same next step.
- **Project cards stayed at their first numbers** (`t-5738`): Total Tickets, Updated, Skills and Branch were read once when the Cockpit loaded, so tickets made while it stayed open showed only after a restart. The cards now refresh when you come back to Projects and every 30 seconds while it is on screen; a failed read keeps the number shown.

## [0.20.4] - 2026-10-26

Two Windows fixes: tickets with letters in their id, and canon's own `.gitignore` lines at close. Update with `canon update`, then restart the board so it loads the new program.

### Fixed
- **Ticket ids with letters past `f`** (`t-b266`): an id such as `t-3tc4` (older or hand-made; `tkt create` still makes hex) was refused by four commands that only took hex digits: `sprint check-evidence`, `evidence.sh stamp|check`, the working-card heartbeat (`work-beat`) and `sprint-check gate-clusters`. They now take `t-[a-z0-9]{4}` like the rest of canon. `gate-clusters` is in the board program, so it needs the next board release to reach an installed machine.
- **`sprint complete` refused canon's own `.gitignore` lines on Windows git** (`t-ae3b`): with `core.autocrlf=true` and an LF-only `.gitignore`, the three lines `skills add` writes were read as a change made after grading. The check now ignores a line-ending carriage return, and a refusal for `.gitignore` or `.gitattributes` prints how the file differs from canon's own edit. `skills add` also says to commit `.gitignore` before starting a sprint.

## [0.20.3] - 2026-10-26

Smaller Windows download. Update with `canon update`; nothing to restart.

### Changed
- **Smaller download for Windows installs** (`t-3954`): the release zip no longer carries canon's own tests, the README screenshots and GIFs (the board's tour keeps its seven images) or the Go source: 12.4 MB in 547 files becomes about 4.1 MB in 279 (the zip itself 6.7 MB to 1.8 MB). Nothing the install runs is removed; the one thing the zip no longer allows is building the programs from source (a failed download then says so and points to `canon update`, a reinstall or a clone). macOS and Linux git installs are unchanged. A fresh install gets the smaller tree; an existing one keeps its old files until it is reinstalled.

## [0.20.2] - 2026-10-26

Search several ticket ids at once. Update with `canon update`, then reload the board page (no restart needed: only the board's page code changed, not its programs).

### Added
- **Search several ticket ids at once** (`t-a5c9`): in the board's search box type two to four characters of each id, without `t-`, separated by spaces or commas (`69f6 1ae4 f066`, or `9f 1ae`), and every ticket whose id contains any of them shows. A query that is not a list of ids is the ordinary search, and nothing the ordinary search found before is hidden.

## [0.20.1] - 2026-10-26

A command that groups repeated gate failures. Update with `canon update`, then stop and start the board (Ctrl+C in the terminal running `canon`, or close its window, then run `canon`). The daemon did not change, so Restart Daemon is not needed.

### Added
- `sprint-check gate-clusters [--days N] [--json]` groups repeated gate failures (evaluator fails, rejected closes, reviewer NOs) by cause from this machine's logs. It only prints (t-b874).

## [0.20.0] - 2026-10-26

A Terminal that opens beside what you are working on. Update with `canon update`, then run **Restart Daemon** in Admin (the daemon's terminal page and command list changed) and stop and start the board (Ctrl+C in the terminal running `canon`, or close its window, then run `canon`).

### Added
- **A Terminal pane next to the tab you are on** (`t-ccf5`): `ctrl+.` then `m` opens the Terminal in a pane below the Board, or below the session tab you are in (`M`: beside), so the Board, or a ticket's GitHub panel, stays on screen. To Claude Cloud now opens its Terminal this way. A draggable handle (arrow keys, double-click to reset) sets the split, which is remembered per project; a window too small for two panes opens a full tab as before. `ctrl+.` then `P` then `n` / `b` / `f` / `l` moves to the next / previous / first / last tab of the current project (the Board and its Terminal pane count as one stop); lowercase `p` is still Projects. The shortcuts sheet lists the new keys. The Terminal's command list is shorter: `su` and `tkt send-issue` no longer wrap over the command column. The daemon's terminal page changed (the prefix handler), so Restart Daemon after updating.

## [0.19.0] - 2026-10-26

A check that canon's own gate files are the released ones. Update with `canon update`, then stop and start the board (Ctrl+C in the terminal running `canon`, or close its window, then run `canon`). The daemon did not change, so Restart Daemon is not needed.

### Added
- **Admin > Integrity** (`t-2af0`): in an install that came from a release, canon compares the seven gate files and five gate prompts with the hashes published for that release, and `sprint complete` refuses to close while one differs (it names the file and the command that puts it back, and records a `gate.rejected` event). The page is read-only: a card for each gate agent (role, model, effort, tools, the prompt it runs), the file lists with a state pill, and what is not covered yet (`install.sh`, `install.ps1`, git hooks, skills, standards). Four states (verified, not a release install, not checked, list pending); only "verified" can block, so an install that follows main, a checkout that is not at a release tag, an offline machine with no saved list, or a release whose list is not published yet never blocks. A match proves a file is unchanged since the release, not that the release was safe; a process that can write to your canon folder or `CANON_HOME` can still change the gate (see `docs/setup.md`). The release now attaches `integrity-X.Y.Z.json` and prints a line for `getcanon.dev/integrity.txt` (`docs/releasing.md` step 5b). `sprint-check integrity [--json] [--gate] [--online]` prints the same check in a terminal.

## [0.18.12] - 2026-10-25

One click from the Sent panel to a Claude cloud session, and a Terminal that can run the cloud workflow. Update with `canon update`, then run Restart Daemon in Admin (the daemon changed) and stop and start the board (Ctrl+C in the terminal running `canon`, or close its window, then run `canon`). A Terminal that is already open keeps the old prompt until you open a new one.

### Added
- **To Claude Cloud** on the Sent panel (`t-0aa7`): after Create issue, one click opens the board's Terminal with `tkt send-issue <id> --launch` already typed; you press Enter. On Windows it copies the line and says to paste it in PowerShell or Git Bash (the Terminal cannot start a cloud session there yet). `tkt send-issue <id> --launch` on a ticket that was already sent now starts the session on its existing issue instead of refusing, and creates nothing.

### Changed
- The Terminal runs ten `tkt` commands without `su`: `create`, `start`, `demo`, `close`, `reopen`, `archive`, `send-issue`, `import-issue`, `open-pr`, `import-results`, each logged as a `terminal.tkt` event (the subcommand name only). `merge-pr`, every other subcommand, and the flags `--test` and `--body-file` still need `su`. `send-issue --launch` runs on your real terminal, as `claude --cloud` requires.

## [0.18.11] - 2026-10-25

Tag lists are checked the same way by `tkt` and the board. Update with `canon update`, then stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again. The daemon needs no restart.

### Fixed
- The board's tag check refuses non-ASCII lists like `tkt` does (`t-3472`): a no-break space or U+2028 at the edge of a list, or the Kelvin sign folding to `k`, no longer passes. A `tags.json` holding `null` is refused like any file that is not an array, and no longer read as empty and replaced by the next added tag.
- `tkt` tag lists refuse non-ASCII on every system (`t-3472`). The lower-casing step ran in the system's own locale, so on a UTF-8 Mac or Windows the Kelvin sign (U+212A) was folded to `k` and accepted, while the board refused it; it now runs in the C locale as the rest of the check does.

## [0.18.10] - 2026-10-25

`canon`, `tkt` and `sprint` now refuse to run in a system folder, a drive root or your home folder. Update with `canon update`, then run Restart Daemon in Admin (the daemon changed) and stop and start the board (Ctrl+C in the terminal running `canon`, or close its window, then run `canon`).

### Changed
- `canon`, `tkt` and `sprint` refuse to run in a system folder, a drive root or your home folder (`t-b2ff`): an Administrator PowerShell opens in `C:\Windows\System32`, and canon there would serve a board for, and fill, a folder nobody keeps tickets in. They print why and exit 1, creating nothing; a git repository there (a dotfiles repository in `~`) still counts as a project, a `.tickets` folder alone does not, and plain folders with no git are unaffected. See docs/setup.md.

## [0.18.9] - 2026-10-25

Dialogs resize from the corner you drag. Update with `canon update`, then stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again. Only the board's web files changed: the daemon needs no restart.

### Fixed
- **Dialog resize** from the bottom-right corner keeps the top-left corner fixed (`t-4803`). It used to grow around the centre, so the top-left corner moved. A corner drag now also stops at the window edge, so no dialog leaves the viewport.

## [0.18.8] - 2026-10-25

The Terminal's `su` now asks for your account password. Update with `canon update`, then run Restart Daemon in Admin (the daemon changed) and stop and start the board (Ctrl+C in the terminal running `canon`, or close its window, then run `canon`). A Terminal already open keeps the old `su` until you open a new one.

- **Terminal `su` asks for your account password** (`t-4pb6`): the OS asks for it (`dscl -authonly` on macOS, `su` to your own account on Linux; on Windows 11 24H2+ with sudo switched on, its UAC prompt), whatever `sudo` is set to, so a passwordless sudo no longer skips it. The random word is gone: with no OS prompt on the machine, or an account that cannot pass it, there is no full shell. In a Terminal tab, End Session, Auto Save, the state chip and Kill are gone or disabled: close it with `Ctrl+.` then `x`.

## [0.18.7] - 2026-10-25

Cards say Working while an agent is on the ticket. Update with `canon update`, then stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again. The board, `tkt` and `sprint` changed; the daemon needs no restart. The new heartbeat starts with the next `tkt start` or `sprint continue`, so a ticket already in progress shows Resume until its agent runs one.

### Added
- **Working** on the board's cards (`t-187e`). An agent you started by hand in a plain terminal used to leave the card saying Resume, and a click started a second agent on the same ticket. The commands an agent runs now keep a small heartbeat, `.tickets/ACTIVE.beat`, and while it is fresh the card shows **● Working**. Click it for how long ago and where; **Resume anyway** still starts the session. When the agent stops or the machine restarts the card goes back to Resume by itself. A live Cockpit session still shows Open / Answer. See docs/sprint-check.md.

## [0.18.6] - 2026-10-25

GitHub Sync now shows a long issue list. Update with `canon update`, then stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again. Only the board changed; the daemon needs no restart.

### Fixed
- **GitHub Sync** shows every waiting issue (`t-862e`). The board used to keep only the last 16 KB of the issue listing, so a repo with about 85 or more waiting issues failed to preview. The listing is now read whole, up to 4 MiB (about 10,000 issues); beyond that the dialog says the listing is too large to show instead of a broken preview.

## [0.18.5] - 2026-10-25

GitHub Sync lets you pick which issues become tickets, and every dialog can be resized from two corners. Update with `canon update`, then stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again. The board and `tkt` changed; the daemon needs no restart.

### Changed
- **GitHub Sync** shows the issues in a table (`t-b045`): Idx, Issue, Reason and a checkbox per row. Issues it would create are ticked, others are disabled with the reason, and a skipped issue whose ticket is closed, cancelled or archived here says `close #N on GitHub`. **Create N selected** makes only the ticked ones. `tkt sync-issues --only 5,7` does the same from the shell (it refuses, writing nothing, a number that is not waiting). `tkt sync-issues --dry-run --json` skipped rows now carry `title`, `ticket` and `ticket_status`. The text route `/api/github/sync-preview` is gone (the dialog reads `/api/github/intake`). Its rows tint on hover (the Logbook's too), and every dialog now resizes from the top-left corner as well as the bottom-right, including this one and New Ticket.

## [0.18.4] - 2026-10-25

`canon update` no longer refuses on a machine where the board has run: the event log and custom themes sit in `~/.canon/events/` and `~/.canon/themes/`, which on a default install is the clone itself, and the update saw them as uncommitted changes. If your update is already refusing with `?? events/` and `?? themes/`, run this once (it only tells git to ignore those two folders; nothing is deleted), then `canon update`: `printf '/events/\n/themes/\n' >> ~/.canon/.git/info/exclude`.

### Fixed
- The repo's `.gitignore` ignores `/events/`, `/themes/` and `/logs/` (ready for Logging), as it did `/cockpit/` (`t-97b1`). `tests/canon-update.sh` now fails if any of the three runtime folders under `CANON_HOME` is not ignored.

## [0.18.3] - 2026-10-25

A small Logbook fix. Update with `canon update`, then stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again. The daemon needs no restart.

### Fixed
- The Logbook's Learnings table keeps a row's status and its destination file (`PROMOTED.md`) on one line each instead of wrapping the file name, and the badge on the Learnings tab shows only when something is still unpromoted (it showed a 0).

## [0.18.2] - 2026-10-25

`canon stop` now stops the board as well as the daemon. Update with `canon update`; stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again.

### Changed
- `canon stop [--force]` stops the Cockpit daemon and then the board, using the same checked stop `canon uninstall` uses: only a board that belongs to this install is signalled, and any other listener on the port is named and left running. It used to stop only the daemon and tell you to press Ctrl+C in the terminal running `canon`. Sessions still make it refuse without `--force`.

## [0.18.1] - 2026-10-25

Admin's daemon panel now shows every version. Update with `canon update`. Only the board's web files changed: stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again. The daemon needs no restart.

### Changed
- Admin's panel, now titled **Canon Cockpit**, lists the same three versions as Help: **Canon**, **Board Build** and **Cockpit Daemon**, with one casing for every row and no `v` prefix on the version. It used to show a single "Current version" that was the board's build under a "Cockpit Daemon" title. Help's Versions block drops the `v` as well.

## [0.18.0] - 2026-10-25

Tickets get tags, the board gets a Logbook and a **Terminal** tab (a restricted prompt in your project: `ls`, `cat`, read-only `tkt`, Tab completion and paging, with `su` for a full shell for 10 minutes), the Cockpit gets a Factory page for the GitHub workflow, and Upkeep is removed. Update with `canon update`. Both the board and the daemon changed: press **Restart Daemon** in Admin (Save & End running agent sessions first: a restart ends them), then stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again.

### Added
- A **Terminal** tab (`t-57ab`, `t-5157`): the **Terminal** button on the board (or `Ctrl+.` then `m`) opens a restricted prompt in your project straight away, with no Start button. It runs `ls` (always the long form, folders blue), `cat` (coloured code; never `.env*` or `.git`), `pwd`, `clear`, `help` (or `?`), read-only `tkt` (`current`, `ls`, `show`, `why`, `github-status`, `github-doctor`) and `su`, which asks for a typed word and then gives a full shell for 10 minutes (warning at 9:30; `exit` or the end of the time returns to the prompt). Tab completes commands, `tkt` subcommands and project paths, Up and Down walk the history, `ls`, `cat` and `tkt` output pages one screenful at a time (Enter or space for more, `q` or Ctrl-C to stop), and Ctrl-C stops only the running command. When the Terminal ends (`exit`, Kill or the idle reaper) its tab closes. It is a convenience boundary, not a sandbox (docs/sprint-check.md). Terminals show as Terminal, with a `>_` mark, in the Agents list and Admin, with "closes in" instead of auto-save, and Kill only.
- **Tags** (`t-37e8`): a ticket carries up to eight tags (`tags: security,nodejs` in its frontmatter), picked from a dropdown in the New Ticket dialog and in the ticket window, shown as chips on cards, and found with `tag:github` in the board search (any case; from three characters the text can be part of a tag, so `tag:git` works; a plain word also matches). The dropdown starts with 20 tags and lets you add your own (saved in the project's `.tickets/tags.json`); `tkt create --tags` and `tkt tags <id>` do the same from the terminal. A tag that is not a plain lowercase word is refused, so a typed tag can never add a line to the ticket file.
- A **Logbook** (`t-c6bb`): a notepad-icon button right after **+ New** in the board header, and a **Logbook** row on each Projects card, open a read-only window over the project's `HANDOFF.md` (its sections as cards) and `LEARNINGS.md` (unpromoted badge, status filter chips, a table where a ticket id opens that ticket). New route `GET /api/logbook`. The file text is shown as text and images in it are not loaded; a missing, symlinked or over-512 KB file says so. The window moves and resizes like the ticket dialog, through a new base dialog (`board-dialog.js`) that a new dialog gets those from; moving the four existing dialogs onto it is `t-cca5`. A board started before this route existed says it is older than the Logbook and to restart it. The review of the promote-learnings report is a follow-up (`t-1a9a`).
- `tkt worktree-reset [--yes | --dry-run]` resets a linked worktree's long-lived tracking branch to origin's default branch once its PR has merged (`t-8f48`), in place of a bare `git reset --hard origin/main`. It fetches first and refuses, with one line naming the fix, wherever the reset would lose work: the main checkout or the default branch, a detached HEAD, uncommitted or untracked files (canon's skill links aside), commits on no remote (a squash-merged branch whose commits are on its remote branch still resets), skip-worktree or assume-unchanged files, a merge, rebase, cherry-pick or revert in progress, or a failed fetch. It prints the commits and files it drops and the new tip, notes the stash and other worktrees (shared, untouched), asks once, and checks again after the answer. It never pushes, deletes a branch or removes a worktree. `sprint complete` run in a linked worktree names it.
- A ticket that went to GitHub gets a **GitHub** tab with its trail (`t-1dec`): `tkt send-issue`, `tkt import-results` and `tkt merge-pr` append a dated entry to `.tickets/<id>/github.md` (issue and PR links, graded head against PR head, evidence OS, merge commit or the refusal reason), so what the import and merge dialogs showed once is kept. Writing it never changes a command's output or exit code.
- A **Factory** page in the Cockpit sidebar, between Projects and Admin (`t-9641`). It is per project, with two tabs. **GitHub** holds the GitHub setup that used to be in Admin (the checks and the Cloud environment recipe), plus an **Intake** box: the `canon` label, the repo, when the project last synced and which labelled issues are waiting. **Agentic factory** says the line is planned and off. Each Projects card gains a Factory row (`GitHub ready · agentic off`, `GitHub needs setup`, or `Not set up`) that opens the page for that project.
- `tkt cloud-env` prints this project's Claude cloud environment recipe, ready to paste: the allowed domains, then the setup script (`t-9955`). A Go project, and canon itself, also gets the Go domains and toolchain step; other projects get only what canon needs. The recipe's one source is `tools/cloud-env.sh`, and Factory › GitHub's Copy buttons use it.
- `tkt import-results` for a cloud ticket that did not close now prints `next: tkt land <id>` and why a local evaluator is needed: the cloud's evaluator run record cannot travel (`t-b650`).
- `tkt land <id>` closes a cloud ticket whose PR the cloud could not grade (`t-c259`): it makes a worktree `<project>-worktrees/land-<id>` on `land/<id>` at the PR head and starts the ticket there; run the evaluator and `sprint complete` in it, then `tkt land <id> --finish` removes the worktree (and the branch, unless it holds commits not on the PR). It never pushes or merges; `tkt merge-pr` still does. The board card shows **Close here** for an imported, unclosed ticket (`github-status --json` gains `land`).
- The daemon's vendored xterm files are now tracked (`t-93ff`). `tools/vendored.tsv` lists each file in `web/vendor/` with its package, the package that now carries new releases, version, upstream, license, SHA-256 and why it is vendored. `tests/vendored-manifest.sh` fails if a file has no row, a row has no file, a file's hash differs from its row or `THIRD-PARTY-NOTICES.md` disagrees. `scripts/check-vendored.sh` prints a table of each package's latest npm version and the OSV advisories that affect the vendored version; it fails only on such an advisory or a failed lookup, and `--sha <file>` prints a row's hash. A weekly, on-demand **vendored-updates** workflow runs it (read-only, no secrets, report-only), and `tests/ci-security-config.sh` now checks every workflow file. See `docs/ci-security.md`.
- A weekly **govulncheck** GitHub Actions workflow for `tools/canon-go` (`t-b525`), also run on demand and on pushes and PRs that touch the Go module. A vulnerability the code can reach fails the job, standard library included, which Dependabot does not cover. It is read-only, uses no secrets and never uses `pull_request_target`, so it is safe on the public mirror. Actions are pinned by commit SHA and govulncheck by exact version, and no Dependabot config is added. `tests/ci-security-config.sh` guards all of this. See `docs/ci-security.md`.
- `tkt sync-issues --dry-run --json` prints the dry run as one JSON object (`repo`, `label`, `waiting`, `skipped`). A completed `tkt sync-issues` writes a `github.synced` event with the number of tickets it made.

### Changed
- Wrapup no longer has a `repo-check` gate (`t-0a7c`), and `doc-audit`'s mechanical checks run in a script. New `tools/doc-check` (no model) checks that relative links resolve, that every `sprint`/`tkt` subcommand in a code span or fence exists, and that every file path a doc names exists. `doc-audit` runs it first, then reads only for overstated claims, missing prerequisites and scope inflation, and skips both when no user-facing doc changed. The canon-only checks (skills lint, `CATALOG.md` drift, orphan scripts, board render) moved to `code-reviewer`. A `## Wrapup Gates` table with no `repo-check` row closes as before, and an older table that still has the row is still accepted.
- **Admin** has tabs: **Model tiers** (the default) and **Logging** (`t-d40b`). The daemon panel and the agent list stay above them on both. The **Desktop notifications** switch and the feature behind it are removed (`t-28ec`, `t-510e`): browser notifications for a session that needs you were never confirmed to fire, and the setting took space on the page.
- Admin > Model tiers keeps what you remove safe (`t-d40b`): Remove on a model that holds a Claude Code alias (`fable`, `opus`, `sonnet`, `haiku`) or a default asks which model takes it over; a replaced model can sit in a collapsed **Legacy** list and be restored; an alias no active model holds shows a banner with a one-click bind. A save that gives two active models one alias, or defaults to a Legacy model, is refused.
- Admin > Model tiers can look for new models (`t-d40b`): **Sources** lists the pages you saved (a docs page, or a provider's own Models API: `api.anthropic.com` or `api.openai.com`, read with your `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`), **Refresh** reads them and proposes what to add and what to retire, and **Apply** writes only the part you pick. Each source shows when it was last checked. A fetch is https only, never reaches a private or loopback address, follows at most 3 redirects, and reads at most 2 MB in 10 s; a key is sent only to the provider's own host and is never shown or saved. The saved registry gains `sources`, `legacy` and per-source check times; Refresh itself writes only those check times.
- `tools/subagent-log.sh` warns on stderr when a Claude Code reviewer or evaluator row is logged with no `--tokens`, naming the `<usage>` notice to wait for (`t-0b61`). The row is still written and the exit code stays 0; other harnesses and the legacy hook path stay quiet.
- Every session now knows the platform rule without being told (`t-5c4b`): the "Active canon skills" block `skills.sh` writes into `AGENTS.md` (loaded by Claude Code, Codex, pi and cloud sessions) carries one line, "on Windows canon's commands run in Git Bash, never PowerShell or cmd", pointing at `standards/efficiency-notes.md` › Platforms (Windows, macOS, Linux, the Claude cloud container). Existing projects get it on their next `skills.sh refresh` or `add`.
- `sprint start` and `sprint continue` warn when canon's gate agents are not loaded in the Claude Code session (it started in another folder, or before `skills.sh add` linked them) and say where to restart, instead of a new user finding out at their first close (`t-ff14`). On the read-only `Plan` fallback, `sprint relay-report <id>` copies the gate's report from the harness's own transcript into its file, so the main session never types a gate report (Claude Code's auto mode refuses that). Events: `sprint.started` gains `gate_agents`, `gate.finished` gains `agent`.
- The mutation sweep now runs before the evaluator on every sprint that changes shell, JS, Python or Go logic (`t-087c`). Kill or triage each survivor, record the final sweep with `evidence.sh stamp <id> mutant-sweep -- mutant-sweep …`, then dispatch the evaluator. It still never blocks `sprint complete`, but its Wrapup Gates row can only read `skipped` with a reason.
- The cockpit daemon's Go tests run in about a third of the time (`t-67a6`: 101 s to 36 s on Linux), so every close and merge waits less. The slow tests run in parallel, shorten the Copilot resume grace, exit drain and scratch reap wait through new per-daemon settings, and poll instead of sleeping. The daemon behaves the same: every default is unchanged, so no restart is needed.
- Factory › GitHub, for a project with no GitHub repo yet, offers `gh repo create <folder> --private --source=. --remote=origin --push` (`t-9955`). Intake also names labelled issues that are already tickets, and the Cloud environment box says to add your own stack's domains.
- The board card's GitHub buttons say what they do: **Issue ↗** and **PR ↗** open GitHub, and **Create PR** creates the PR a cloud session did not (they were all "Open …", `t-9955`).
- Buttons follow one rule on the board and in the Cockpit (`t-e523`): red means it stops or deletes something, neutral means it only closes. Close, Cancel and a tab's × share one hover; Stop, Kill, Discard, Deregister and Remove are neutral until hovered, then red border and text (they used three different reds, some solid). A main danger action (Stop Daemon, Deregister ✕, a danger confirm's button, the GitHub dialog's Stop) fills red on hover. Sub-actions beside a filled main action (Sync from GitHub, Upkeep, Scratch, CI, `+ efficiency`, Resume) show the accent on their border on hover; `+ efficiency` is no longer red. The colours live in one stylesheet, `static/buttons.css`.
- The board's GitHub dialog keeps its log to 16 lines with a scrollbar and follows new output unless you scroll up; `tkt merge-pr`'s repeated "running …" progress shows as one live line; the dialog moves by its title and resizes from its corner; Escape no longer closes it while a step runs (`t-e523`). A board tab no longer shows the project name as a tooltip over the whole board.
- The board's **GitHub Sync** button (it was **Sync from GitHub**) is greyed out until the GitHub checks pass (no GitHub origin included). Its tooltip points to Factory › GitHub. The worktree picker's "GitHub · set up first" row opens Factory › GitHub instead of Admin.
- **Keys** (`t-5157`): `Ctrl+.` then `x` closes the open session tab (a Scratch, a ticket) and lands on the project's board; with none open it closes the project tab, as before, and a live Terminal still asks first. `w` folds the open tab's side panel (the Workspace sidebar when no tab is open) and `c` always folds the Workspace sidebar. The Keyboard sheet tints a row on hover, and the open-tab strip lines up with the Search group.

### Security
- The weekly vendored-updates report also watches the CI gate template's pins (`t-2d0f`): the Node in `tools/canon-gate-template.yml` against the newest `"security": true` release of its major on nodejs.org (a newer one fails the job, naming the fixed-in version), and the Claude Code CLI against npm's latest and its OSV advisories. A failed lookup still exits 2, never 0. `tests/ci-security-config.sh` now also refuses a leading-zero or absurd `node-version`, a flow-style `env: {…}`, and a `strategy` matrix in the template.
- **The canon-gate workflow now installs its own patched Node** (`t-c4b4`). The generated `canon-gate.yml` ran the Claude Code CLI on whatever Node the GitHub runner image shipped (22.23.3 on the 2026-10-12 image, one patch below the fix for the Node HTTP-client Brotli CVE). It now sets up an exact, patched Node with `actions/setup-node` pinned to a commit SHA (22.23.4, CVE-2026-111497 fixed, the package-manager cache off) and installs the CLI on it, both before the PR is checked out so no file of the PR can steer them, and `tests/ci-security-config.sh` refuses a template that drops or reorders the step, floats the version, falls below the patched floor, adds another key, a second job, an `if:` or an environment override, or turns the cache on. Existing `canon-gate.yml` files are not rewritten: delete the file and run **Set up CI gate** again to adopt it.

### Removed
- **Security: Upkeep is removed** (`t-0e8b`). The board's Upkeep button, the Projects cards' "never run" counts, the `/api/upkeep/run`, `/status` and `/report` routes (they now answer 404), `tools/upkeep-run` and its `.cmd` shim, the skill-hash manifest and its updater are gone. Upkeep let one click start an unattended `claude -p` over a project root with Write allowed. Write cannot be scoped to a path, so "write only the report" was enforced only by the prompt, and the repo content the agent read was the prompt-injection input; the skill-hash pin only caught a `SKILL.md` that changed after clone, not a malicious committer or the other files in the repo. The four checks stay as plain skills you run in a fresh interactive session (`/context-check`, `/context-doctor`, `/dead-code-cleanup`, `/promote-learnings`), with `tools/dead-code-scan.sh` and `tkt create --skills`. Skill Eval moves to its own view, opened from a project's card (its **Skill Eval** row). An old `.reports/upkeepRuns.json` is ignored. A scheduled run, if one is ever wanted, comes back as a separately approved feature with the Write path scoped.

### Fixed
- `skills.sh add`/`init`/`remove`/`status` and `scripts/install-hooks.sh` find the git hooks folder in a linked worktree, where `.git` is a file (`t-80fc`): they asked for `<dir>/.git/hooks`, so in a worktree they skipped the pre-commit hook as "not a git repo". They now ask git for the common git dir (`tools/hooks-lib.sh` `_git_hooks_dir`); a plain folder without its own `.git` still skips. `tests/helpers.sh` gains `git_dir` / `git_common_dir`, and `tests/worktree-suites.sh` runs the hook installers from a worktree.
- The Go toolchain pin is raised to go1.27.3 (`t-8bcd`): govulncheck found GO-2026-6809 in `crypto/x509` of go1.27.2 (reported through `daemon.Run` → `fmt.Fprintf` → `x509.Certificate.Verify`; the daemon and board make no TLS calls, only plain `http://` to the daemon on loopback, so it is not reachable in practice). The released daemon and board binaries are rebuilt with 1.27.3; a machine whose `go` is older than the pin downloads the toolchain on first use, so `brew upgrade go` (or your package manager) keeps tests from downloading it into every scratch home.
- `tests/pipefail-early-exit.sh` scans the files git knows (tracked and new, not gitignored) instead of every file on disk, so a personal untracked script no longer fails the suite on one machine (`t-8bcd`).
- `tkt merge-pr` waits out GitHub's `mergeable: UNKNOWN` (up to 6 reads, 5 s apart, one progress line each) instead of refusing right after another PR merges; CONFLICTING, BLOCKED and other states still refuse at once (`t-fefb`).
- `sprint start`'s gate-agents warning names the right folder again (`t-21f7`). A session started outside the project was told to restart in that outside folder and run `skills.sh refresh` there; it now names the project. A session started in the project or one of its git worktrees is still told to restart there (`t-12f8`).
- Nothing reaches canon-skills before its binaries are released, whichever way it is pushed (`t-4ea4`). `scripts/install-hooks.sh` adds a pre-push hook: a push to a `canon.mirror` remote (`public`) runs the same check as `tkt push-main` (now one function, also `tkt release-check <sha>`), so a plain `git push public` of an unreleased commit is refused. The release steps (`docs/releasing.md`, the close checklist) now say `public` goes only through `tkt push-main`; they used to say `git push public main`.
- **Push main to public** (`tkt push-main`) no longer publishes a commit whose daemon or board binaries are not released yet (`t-b6b6`): it checks origin's commit with `scripts/check-binaries-released.sh --rev` and says to run `scripts/release-daemon.sh` first. Other projects push as before.
- `mutant-sweep` no longer lets a mutant write into your real home (`t-eb40`): each mutant's test now runs with `HOME` pinned inside its temp copy too, with the Go and Playwright caches passed through. After every sweep a canary scans the real `~/.canon` for the sweep's temp path; a hit prints `mutant-sweep: LEAK <file>` and exits 4. Found when a mutant wrote 11 fixture events into `~/.canon/events` (`t-f182`).

## [0.17.0] - 2026-10-20

The event log now covers close gates and Cockpit sessions too: when a gate starts, how it ends, why a close was refused, and when an agent session needs you, ends or is saved (docs/plugins.md). Update with `canon update`. Both the board and the daemon changed: press **Restart Daemon** in Admin (Save & End running agent sessions first: a restart ends them), then stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again.

### Added
- The event stream records close gates and Cockpit sessions too (`t-8854`): `gate.started`, `gate.finished` (with the verdict, model and tokens), `gate.rejected` (with a reason code), `session.needs_you`, `session.exited` and `session.saved`. See [docs/plugins.md](docs/plugins.md). The close checklist passes `--role reviewer|evaluator` to `gate-snapshot.sh pre`. The cockpit daemon changed (it writes the session events): after `canon update`, press **Restart Daemon** in Admin, which ends running agent sessions (Save & End them first), or the old daemon keeps running without them.

## [0.16.0] - 2026-10-20

canon now keeps an event log: every ticket and sprint change becomes one line in `~/.canon/events/`, so plugins and scripts can follow along (docs/plugins.md). Update with `canon update`, then stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again. The daemon did not change: don't restart it, and agent sessions keep running. Claude cloud environments: copy the setup script from docs/setup.md again if yours still reads `tools/cockpit-daemon/go.mod`.

### Added
- An event stream (`t-f182`): `tkt`, `sprint` and the board record ticket and sprint changes as one JSON line each in `~/.canon/events/<UTC day>.jsonl`, so plugins and scripts can follow along without polling. Schema v1 (`ticket.created`, `ticket.status_changed`, `ticket.closed`, `sprint.started`, `sprint.completed`) is documented in [docs/plugins.md](docs/plugins.md). Writing an event never changes what a command does; files older than 90 days are deleted.

## [0.15.0] - 2026-10-20

canon no longer needs Python anywhere you use it: the board program does the JSON work that `python3` did, so a Mac or Linux machine without Python now gets the install deny rules, and headless runs need nothing beyond canon's own programs. Update with `canon update`, then stop the running board (Ctrl+C in the terminal running `canon`, or close its window) and run `canon` again to start the new one. The daemon did not change: don't restart it, and agent sessions keep running.

### Changed
- canon no longer runs Python anywhere you use it (`t-b62a`). The board binary gained helper commands (`headless-json`, `json-strings`, `settings`, `skill-check`) that replace the inline `python3` in `sprint-headless`, `sprint-headless-eval` and `skills.sh`, Windows' `settings-merge.ps1`, and the Python `tools/skill-check` (now `sprint-check skill-check`). `sprint-headless-json-win.exe` is retired; an old copy left in `tools/` is harmless.
- `sprint-headless` and `sprint-headless-eval` check the board binary before calling `claude -p`, so a missing one fails before a paid run, not after it.

### Fixed
- On macOS and Linux without `python3`, `skills.sh add sprint` skipped the install deny rules (close gates could then run `brew`/`apt install`). It now writes them on every OS, keeping the rest of `.claude/settings.json` as it was (key order and values); a symlinked settings file is refused.

## [0.14.0] - 2026-10-19

The board and the cockpit daemon now build from one Go module, `tools/canon-go`, and each is still released on its own, so a fix to one no longer re-releases the other. Update with `canon update`, then press **Restart Daemon** in Admin (both binaries changed since 0.13.0; a running daemon stays on the old version). Claude cloud environments: copy the setup script in again (see below).

### Changed
- The board and the cockpit daemon are one Go module, `tools/canon-go` (one `go.mod`, one pinned Go), still built as two programs with the same names and places. Each is released under its own key, so a board-only fix no longer re-releases the daemon (`t-8020`). **Claude cloud environments:** copy the setup script from `docs/setup.md` (or Admin › GitHub) into your environment again; it now reads the Go pin from `tools/canon-go/go.mod`.

### Fixed
- The board refuses a doc path with a `..` segment (`/api/doc/t-x/..%2Fplan.md`) with 400. Release builds had answered 200 and written `.tickets/plan.md`, inside the tickets folder but outside the ticket (`t-8020`).

## [0.13.0] - 2026-10-19

The board is one Go program on every OS: macOS and Linux no longer run a Python board, and `server.py` is gone. The board is now a checksummed download beside the daemon, like Windows already had. Also new: the board drives the GitHub workflow (send an issue, check and merge its PR), and gate runs log their model. Update with `canon update`, then press **Restart Daemon** in Admin (the daemon changed since 0.12.1; a running one stays on the old version).

### Removed
- `tools/sprint-check-app/server.py`, the Python board. Python is no longer needed to run the board on macOS or Linux (it stays optional for `sprint-headless` JSON and `skills.sh` settings merges) (`t-15d8`).

### Added
- `subagent-log.sh --model <id>` records the model a gate run was dispatched on (the one the orchestrator resolved, not one read from the transcript), and `sprint gate-cost` groups by gate, tier and model, showing `-` for a row without one. The id is checked (`[A-Za-z0-9._:/-]`, at most 80 characters) and a row without the flag is unchanged. The close recipes pass it (`t-3a14`).
- `mutant-sweep` also sweeps Python (`.py` or a python shebang, checked with `python3 -m py_compile`) and Go (`.go`, checked with `gofmt -e`) files, from the same operator table: and/or, not, is/is not, in/not in, None/True/False, comparison and off-by-one, return values and codes, `sorted()`/`set()`/`.sort()` removal, emptied strings and dropped anchors; Go adds `err != nil`, `!= nil` and `os.Exit` codes. Comments, docstrings, block comments and the inside of strings are never mutated, and a mutant that does not parse is `INVALID`, not a survivor. Shell and JS output and exit codes are unchanged (`t-a3ef`).
- `tkt github-status <id> [--json]` says where a ticket sent to GitHub stands: `sent`, `pr-open`, `results-ready` (its results branch is waiting: import it), `results-in` (imported; the evaluator passed on the PR's head) or `merged`. Read-only: one `gh` call and one `git ls-remote` (`t-d271`).
- `tkt take-back <id> [--close-issue]` brings a ticket sent to GitHub back to this machine (`t-d271`). It clears `runs: github` and keeps the `github:` link to the open issue; `--close-issue` closes the issue and clears the link too (`t-718b`).
- The board runs the GitHub workflow (`t-718b`). **▶ Start** offers GitHub as a place beside Main and the worktrees: picking it previews the issue and, on **Create issue**, sends it, with no terminal. A ticket out on GitHub sits in In progress with a `GitHub #N · <stage>` chip and one button for the next step: Open issue, Open PR, Import results, or **Check & merge**, which shows the checks and asks once before running the PR's code. Its status is polled every 2 minutes while the page is visible, and **take back** brings it home.
- The board's servers (Python and Go) run the GitHub workflow commands for the coming board UI: send-issue (preview and send), sync-issues (preview and create), import-results, merge-pr (`--check`, and `--yes` as a background job whose progress the page can follow), take-back and github-status (cached 30 s per ticket), each one `tkt` command in the project. On Windows the Go board runs `tkt` through `tools/tkt.cmd`. The merge job can be stopped, and stops itself after an hour (`t-d271`).

### Changed
- The board on macOS and Linux is the Go board, `tools/sprint-check-bin/sprint-check`, fetched from the release (`sprint-check-<key>`, darwin-arm64/amd64 and linux-amd64/arm64) and checked against `tools/cockpit-daemon.sha256` before it runs; `canon` checks it at every start and, on a checkout with Go, builds a committed but unreleased board from source. The daemon the board starts now runs in its own session (a Ctrl-C in the `canon` terminal no longer reaches it), and board git calls never wait on a credential prompt (`t-15d8`).
- `tkt send-issue` writes the issue's "Working on this" as six numbered steps (import first, plan, branch, build, gates, export) instead of one paragraph, so a cloud session cannot read past the pipeline (`t-67c5`). Issues already sent keep their wording.
- `scripts/test.sh` starts its seven slowest suites first (`LONGEST`, from a full run's `== slowest 10`), so the 188 s suite no longer starts a minute in: a full run took 215 s instead of 251 s (median of three clean-clone runs each). Output order, `--list`, the SERIAL suites and the exit code are unchanged (`t-b792`).
- `tkt send-issue` also writes `runs: github`, which is what marks a ticket out on GitHub; `github:` is only the issue link, which `sync-issues` and `import-issue` write too, so a synced issue stays an ordinary local ticket. `send-issue` refuses a ticket already linked to an issue rather than open a second one, and `--dry-run` previews a public repository (it creates nothing) (`t-718b`).
- `tkt send-issue`: the issue's "Working on this" block tells the cloud session to write the plan, stop and wait for approval before editing any file but the ticket's docs, to stop and tell the user if Acceptance or Plan read "(none yet)", and to work on a new branch, push that branch and open a PR, never pushing to main or force-pushing. `tkt export` warns (and still exports) when `acceptance.md` has no criteria or the plan's Sign-off box is unticked (`t-1cf4`).

## [0.12.1] - 2026-10-16

`tkt merge-pr` shows progress and can check without running, and cloud sessions are steered away from plan mode, with a documented way to finish one on your machine. Update with `canon update`. No daemon change: nothing to restart.

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
