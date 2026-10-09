# Canon Setup

> **Windows 11 — no WSL, no git clone needed:** in PowerShell run `irm https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.ps1 | iex`. It offers to install Git for Windows (for its bash) with winget, fetches canon into `%USERPROFILE%\.canon`, and adds its tools to your PATH; re-run it, or run `canon update`, to update. Already have a clone? Install [Git for Windows](https://git-scm.com/download/win), then:
> 1. Run **`install.cmd`** once (double-click it, or run `install.cmd` from any terminal) — it launches `install.ps1` for you and adds `tools/` to your user PATH. Running `install.ps1` directly can fail with *"not digitally signed … UnauthorizedAccess"* (Windows' PowerShell execution policy blocking unsigned scripts); `install.cmd` sidesteps it with a process-scoped bypass, or run `powershell -ExecutionPolicy Bypass -File .\install.ps1` manually.
> 2. Use **Git Bash** to clone canon and run `git pull` to stay updated.
> 3. Use **PowerShell** for everything else: `sprint-check-win` opens the board; create and manage tickets through the UI.
>
> For agent-driven workflows (`sprint`, `tkt`, `skills.sh`), run those commands from Git Bash. WSL2 also works — see [fresh-machine-test.md → Windows 11](fresh-machine-test.md#windows-11).

## Install

**Step 1 — Clone canon**

Use the one-line installer from the [README](https://github.com/sunitghub/canon-skills#canon), or clone manually:

```bash
git clone --depth 1 https://github.com/sunitghub/canon-skills.git ~/.canon
```

The one-line installer makes the same shallow clone (`--depth 1`): about 20 MB, not the roughly 415 MB of full history. `canon update` keeps working on it. For the full history of `main`, run `git -C ~/.canon fetch --unshallow`; other branches are not fetched by a shallow clone (`git -C ~/.canon remote set-branches origin '*'` then `git -C ~/.canon fetch` adds them).

The Cockpit's agent sessions (Scratch, Start sprint) need the **cockpit daemon**, a small Go program. A clone has only its source, so the one-line installer, `canon update` and the first `canon` run fetch the prebuilt binary for your Mac or Linux machine from a canon-skills release and run it only after its SHA-256 matches `tools/cockpit-daemon.sha256`. If the download is unavailable they build it from source when Go 1.26.5 or newer is installed (`brew install go`), otherwise they print what to do. After a manual `git clone` or `git pull`, run `canon update` to fetch or refresh it. On Windows the same fetch provides `cockpit-daemon-win.exe`, `sprint-check-win.exe` (the board when there is no Python) and `sprint-headless-json-win.exe`: the installer and `canon update` download them, check each against `tools/cockpit-daemon.sha256`, and keep the ones you already have if a download fails (they are no longer committed). Third-party licenses for the modules compiled into the daemon are in `THIRD-PARTY-NOTICES.md`.

**Custom location.** `CANON_HOME=/path/to/dir bash <(curl -fsSL https://getcanon.dev/install.sh)` installs to that folder instead of `~/.canon`.

**Step 2 — Run init (once)**

```bash
~/.canon/tools/skills.sh init
```

Installs a git-native `.git/hooks/pre-commit` (enforcement: ticket-direct-close block, high-risk Sign-off gate, test suite, wrapup reminder) and copies the Pi handoff extension when Pi is installed. Canon installs zero Claude Code hooks in `.claude/settings.json` — `HANDOFF.md` is read explicitly by sprint's `sprint start` step and refreshed explicitly by `wrapup`'s doc-refresh step, not injected by a hook. Re-run if you move the canon folder.

**Step 3 — Register sprint in your project**

```bash
cd /path/to/your-project
~/.canon/tools/skills.sh add sprint
```

If prompted to add canon tools to PATH, answer `y`, then run the printed `source ~/.zshrc` or `source ~/.bashrc`. Verify with `skills.sh status`.

`add sprint` pulls in the full workflow dependency stack automatically. Most projects need nothing else. Add optional skills individually when a project needs them.

`skills.sh add` writes skill registration to `AGENTS.md` (the file Codex and Pi read natively). Claude Code reads `CLAUDE.md` instead, so `add` also creates `CLAUDE.md` with a single `@AGENTS.md` import the first time you register a skill — bridging the two so Claude Code actually sees what's registered. If `CLAUDE.md` already exists without that import, `add` prompts before appending it rather than touching your existing content silently.

**Open the Cockpit**

Run `canon`. It opens the Cockpit at `http://127.0.0.1:8899/cockpit`; a second run focuses the same window. To use another port, run `canon <port>` or set `CANON_COCKPIT_PORT`.

### Uninstall

You don't need to close the Cockpit first: `canon uninstall` stops this install's own board and daemon itself. Run it from an ordinary terminal, not from a terminal inside the Cockpit (a Scratch session): it refuses there, because stopping the Cockpit would end the command itself.

```bash
canon uninstall --dry-run    # print the plan, change nothing
canon uninstall              # print the plan, ask, then remove
```

Tested on macOS and, on Windows 11, from PowerShell (full removal and `--keep-data`). cmd (`canon.cmd`) and Git Bash run the same bash script but were not tested on a real machine; Linux follows the macOS path and is untested. The macOS and Linux Cockpit stop (board, daemon, runtime state) is verified on a Mac with throwaway processes and the real daemon binary; on Windows it is stop-by-path (only the Go board, `sprint-check-win.exe`, is recognised; a Python board is refused as unidentified) and was exercised only against stubs until a VM run. Options: `--yes` skips the prompt (with no terminal and no `--yes` it only prints the plan and exits 2), `--keep-data` keeps the Cockpit data (`~/.canon/cockpit`: project registrations and the restore snapshots of projects without git) and your skills registrations, `--force` also ends live agent sessions (without it, running sessions make the uninstall refuse and name how many).

What it does, in order: stops this install's Cockpit daemon and board (found by the pid and port they record and checked against this install, never by name; it refuses while agent sessions are live unless `--force`, and signals with SIGTERM only (on Windows `Stop-Process`, which cannot be graceful), so a process that will not exit is reported and nothing is deleted), runs `skills.sh uninstall` for every project registered with skills.sh or the Cockpit (git pre-commit hook, legacy Claude Code hooks, skill and agent symlinks, canon imports, the Pi handoff extension, `~/.config/canon`), removes empty `.claude/` and `.agents/` folders it leaves, deletes the Cockpit data, the daemon's runtime state in the temp folder (`canon-cockpit-board`, one per machine, so a reinstall shows no stale "session was running" banner; a second canon install whose daemon is running keeps its own) and the install folder, and on Windows removes `<install>\tools` from your user PATH (the old PATH value is printed first; a PowerShell helper deletes the folder after the command exits and writes its result to a log).

Left on purpose: your projects' `.gitignore` canon lines, the `.gitattributes` canon block, the `@` imports in `AGENTS.md` and `CLAUDE.md`, `PROMOTED.md` and `.tickets/`. Shell rc lines such as `export PATH="$PATH:<install>/tools"` are reported with file and line number, never edited.

Safety: the install folder is deleted only when it is a canon install (`tools/canon` and `tools/skills.sh` exist, it matches `~/.config/canon/install_path` when that file exists, it is not `/` or your home folder or a parent of it) and, if it is a git clone, when it has no uncommitted or untracked changes, an upstream branch with nothing unpushed, no local branch with commits on no remote, no stash, no linked worktree and no skip-worktree edits. Otherwise it is kept and the exact `rm -rf` is printed, even with `--yes`. Any other process running from the install folder blocks the run; it is never killed.

## Session continuity

No hooks fire automatically for this — canon installs zero Claude Code hooks. `sprint start`'s
context step explicitly reads `HANDOFF.md` at the start of a sprint; `wrapup`'s doc-refresh step
explicitly updates it at close. Keep the content inside `HANDOFF.md`'s `<!-- canon:handoff:BEGIN/END -->`
markers under 80 lines (checked at close time; content you add outside those markers isn't counted).
Prune stale entries freely — git history preserves everything.

## Tracking `.tickets/` in your project

canon keeps its **own** working `.tickets/` gitignored (they're canon's internal dev tickets, not
product). **Projects that consume canon should do the opposite — track `.tickets/` in git, don't add
it to `.gitignore`.** Your sprint state (`acceptance.md`, `plan.md`, `summary.md`, and any
ticket-local `features/*.feature` specs) is the durable record that survives context resets, and it
must be committed for two reasons:

- **Headless CI grading** reads the graded ticket's `acceptance.md` from the checked-out repo — an
  uncommitted ticket is invisible to the PR gate.
- **Ticket-scoped `.feature` references** (a criterion pointing at `features/<name>.feature` under
  the ticket) only render on the board and reach CI if the file is committed with the ticket.

If you started from a template that gitignores `.tickets/`, remove that line so your agent's planning
and specs travel with the repo.

**Runtime files are the exception — don't commit those.** canon writes a few per-machine files under
`.tickets/` that change every session and must never be tracked: `.tickets/ACTIVE` (the active-sprint
pointer) and the cockpit's `.tickets/<id>/.cockpit-*` files (`.cockpit-cwd`, `.cockpit-agent`,
`.cockpit-session-id`). `tkt` auto-seeds a `.tickets/.gitignore` covering them (`.cockpit-*`, `ACTIVE`)
the first time it ensures the tickets directory exists — so on a project that tracks `.tickets/`, the
ticket docs are committed while the runtime churn is ignored. Commit that `.gitignore`. If your repo
**already committed** any runtime files (e.g. from before this was seeded), untrack them once — they
stay on disk, they just stop being versioned:

```bash
git rm -r --cached --ignore-unmatch '.tickets/**/.cockpit-*' '.tickets/ACTIVE'
git commit -m "stop tracking canon runtime files"
```

Leaving them tracked otherwise causes the cockpit's worktree carry-over check to false-warn about
"uncommitted changes" whenever canon writes or deletes one of its own runtime files (t-2f53).

## Skill lifecycle

See **[standards/skill-setup-std.md](../standards/skill-setup-std.md)** for the lint → eval → register order of operations.

## Reference

### Skills commands

```bash
skills.sh list                    # show available skills
skills.sh add sprint              # register a skill in current project
skills.sh status                  # check registration + hook health
skills.sh refresh                 # re-register, repair symlinks, prune legacy imports
```

### Ticket commands

```bash
sprint current                    # active sprint
sprint status                     # active sprint + required files
tkt ls                            # list all tickets
tkt ls --status=in_progress       # filter by status
tkt show <id>                     # full ticket detail
tkt reopen <id>                   # reopen a closed ticket
```

### Skill verification

| Skill | Trigger | Expected |
|-------|---------|----------|
| `sprint` | `"Start a sprint for X"` | Tier selected → brief → awaits approval → writes plan.md |
| `context-check` | `/context-check` | Context audit; writes context-check-report.md at the project root |
| `doc-audit` | `/doc-audit` | README/guides audit; findings appended to doc-findings.md |
| `output-validator` | `/output-validator` | Pre/post-generation report validation |
| `skill-export` | `/skill-export <name>` | Exports flat skill as paste-ready text |

## Staying updated

```bash
cd ~/.canon && git pull
```

If `canon update` refuses with "has uncommitted changes" and `git -C ~/.canon status --short` shows only `?? cockpit/` (installs made before this fix, 2026-10-06), run `git -C ~/.canon pull --ff-only` once. A plain pull is not blocked by that folder, and after it `canon update` works.

To stay on a release, or go back to one after a bad update: `canon update --to v0.3.0` pins the install to that tag (the daemon and your projects are refreshed as in a normal update), and `canon update --to main` follows main again. An install made before 2026-10-08 does not know `--to` yet (`canon update takes no arguments`): run a plain `canon update` once, then `--to` works. On a git install, a plain `canon update` refuses while pinned and says so. Releases and what each contains: `CHANGELOG.md`; how a release is cut: `docs/releasing.md`.

**Verified installs.** A release (`--to vX.Y.Z`) is checked against the manifest at `https://getcanon.dev/releases.txt` before it is installed: on a git install the tag's commit must equal the manifest's, on a Windows zip install the downloaded zip's SHA-256 must equal it (checked before extraction). If the manifest cannot be read, does not list the release, or disagrees, the install refuses, says why, and changes nothing; there is no override, and `canon update --to main` is the way out. `main` is not verified (it changes with every push), and the one-line installer installs `main`, so it prints a note saying so. This protects against a corrupt or changed download and a compromise of the zip alone; it does not protect against someone who controls the installer script, which is served from the same GitHub repo. Details: `docs/releasing.md`.

Hook scripts update immediately — called by path. Skill content updates automatically via symlinks (`.claude/skills → ~/.canon/skills` and `.agents/skills → ~/.canon/skills`, for Codex/Pi) — every project picks up changes on the next session.

`add`/`refresh` also add `/.claude/skills` and `/.agents/skills` (no trailing slash, so a macOS/Linux symlink is matched too) to your project's `.gitignore` — the skill dirs are **local links to canon, never committed**. An older `/.claude/skills/` line is replaced in place on the next `refresh`. This matters on Windows, where the link is a directory *junction* that git sees as a real folder: committing it would freeze a copy of the skills, and any `git worktree` or older checkout would then serve **stale** skill guidance (a canon fix would look absent). If your repo already committed the mirror, `add`/`refresh` untracks it (`git rm --cached`, files untouched) so it stops drifting. Git worktrees are auto-linked to current canon when the board (`sprint-check`) creates them; for a worktree made by hand, run `skills.sh link-worktree <path>`. If a worktree materializes a **committed** mirror (a repo that tracked `.claude/skills`/`.agents/skills` before you untracked it), worktree creation now **replaces** that stale copy with a fresh link to current canon and untracks it in the worktree — so the worktree serves current skills immediately. The durable, all-checkouts fix is still the one-time main-repo untrack: run `skills.sh refresh` in the main checkout and commit the removal.

To repair symlinks after an upgrade:

```bash
skills.sh refresh /path/to/your-project
```

## Requirements and Windows

| Tool | Required | For |
|---|---|---|
| Claude Code / Codex / Pi | At least one | running the agent |
| Git | Yes | clone/update canon |
| Bash | Yes | CLI tools (`sprint`, `tkt`, `skills.sh`) |
| Python 3 | `sprint-check` on macOS/Linux | the board — Windows uses the Go binary, no Python needed |
| curl | macOS/Linux | fetching the prebuilt cockpit daemon (agent sessions) on install and `canon update`; checked against a SHA-256 in the clone before it runs. Go 1.26.5+ is only a fallback that builds it when the download is unavailable |

**Windows 11 — no WSL, no git clone needed.** In PowerShell, run the one-liner. It offers to install Git for Windows (for its bash) with winget if missing, fetches canon as a zip into `%USERPROFILE%\.canon`, and adds `tools\` to your user PATH; re-running updates in place and keeps `cockpit\`:

```powershell
irm https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.ps1 | iex
```

No PowerShell policy change is made. Prefer to read it first? Download `install.ps1`, open it, then run `powershell -ExecutionPolicy Bypass -File .\install.ps1` (process-scoped). From cmd: `curl.exe -fsSLO https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.cmd && install.cmd`. Set `$env:CANON_YES=1` to skip the Git prompt. Then open a new terminal and run `canon`.

Already have a clone? Install [Git for Windows](https://git-scm.com/download/win), then:
1. Run **`install.cmd`** once — double-click it, or run `install.cmd` from any terminal. It launches `install.ps1` for you and adds `tools/` to your user PATH. (Running `install.ps1` directly can fail with *"install.ps1 is not digitally signed … UnauthorizedAccess"* — that's Windows' PowerShell execution policy blocking unsigned scripts, not a canon bug. `install.cmd` sidesteps it with a process-scoped bypass; if you prefer the `.ps1`, run `powershell -ExecutionPolicy Bypass -File .\install.ps1`.)
2. Use **Git Bash** to clone canon and run `git pull` to stay updated.
3. Use **PowerShell** for everything else. Each command has a `.cmd` wrapper in `tools/`, so run it by name: `canon` or `sprint-check-win` opens the board, and `sprint`, `tkt` and `skills` (for example `skills refresh`) run canon's CLI through Git Bash for you.

In a **Git Bash** window the same tools work too, but use the script names: `skills.sh refresh`, not `skills refresh` (Git Bash doesn't run `.cmd` files, and `tools/skills` is a folder). See **[fresh-machine-test.md → Windows 11](fresh-machine-test.md#windows-11)** for the full setup.

**Git for Windows is the only dependency on Windows.** canon never requires Python there:
- `canon` and `sprint-check` start the Go `sprint-check-win.exe` when there's no working Python. It is fetched and checksum-verified (not part of the repo); if it is missing, `canon` tries one quiet fetch before telling you to run `canon update`.
- `skills.sh` edits `.claude/settings.json` (the permission and deny rules) with Windows' built-in PowerShell.
- `sprint`, `tkt` and the pre-commit hook use only bash.

canon never *runs* a `python3` found under `…\AppData\Local\Microsoft\WindowsApps\`. That's an App execution alias, and on some machines running it downloads and installs Python. A test, `tests/no-python-windows-paths.sh`, fails if an end-user script starts depending on Python.

### Windows: what's different

- **The board runs the Go binary** (`sprint-check-win.exe`) unless a working Python is found, so a few board features behave differently from macOS/Linux.
- **Command names depend on the shell:** PowerShell and cmd use the `.cmd` wrappers (`skills refresh`), Git Bash needs the script names (`skills.sh refresh`).

Adding or removing a Windows gap? Update this list in the same change.

Register canon in another project:

```bash
~/.canon/tools/skills.sh add sprint          # plan → build → ship (includes wrapup, handoff)
~/.canon/tools/skills.sh add context-check   # optional: context-budget audits
```

**A project that isn't a git repo** (common for PM and design folders) is a first-class project: register it and start an agent as usual. canon records what the agent changed from a snapshot it keeps outside the folder (under `~/.canon/cockpit/changes/`), and the End dialog and the ticket's **Changes** panel show it in plain words. Each card on the Projects page also shows a git icon beside the project name (hidden if its status check fails), for version history you can opt into. Hover it for its state: *Git enabled — this project keeps a version history*, *Git not enabled — click to turn on version history*, or *Version history needs Git, which isn't installed on this computer* (the icon is disabled then). Click the "not enabled" icon and confirm, and canon creates a local history in that folder (`git init`, a `.gitignore`, and a first commit containing only that `.gitignore`). Nothing is uploaded and your files stay uncommitted. canon refuses if the folder already has a `.git` or sits inside another repository, and warns for iCloud Drive, Dropbox, OneDrive and Google Drive folders, where sync can damage that history.
