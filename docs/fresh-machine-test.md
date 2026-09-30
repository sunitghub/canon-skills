# Fresh Machine Test

Validates that canon is self-contained and works on a machine where none of your dev-box config exists. Uses a UTM virtual machine.

**What this proves:** canon installs, wires hooks, runs its CLI suite, and shows the board — with no help from your global dotfiles, Homebrew setup, or pre-existing `~/.claude` config.

---

## 1. Guest OS

**Recommended: macOS** — the only guest type that surfaces hidden global-config dependencies. UTM supports macOS Sequoia/Sonoma on Apple Silicon via IPSW restore images.

**Linux alternative: Ubuntu 22.04 Desktop ARM64** (UTM gallery) — fast to spin up, exercises the Linux-path fallbacks (`xdg-open`, `ss`) but won't catch macOS-specific config drift. Use for portability checks, not the primary validation.

Headless (server) Linux is sufficient for the CLI suite and install tests, but **not** the board step, which requires a browser.

**Windows 11 developers:** canon's CLI tools are bash scripts — on Windows 11 the supported path is Git for Windows (Git Bash), no WSL required. See [Windows 11](#windows-11) below (WSL2 is an optional alternative). The UTM Windows 11 ARM64 image lets you test the Windows path on your Mac.

---

## 2. Prerequisites in the VM

Install these before running anything canon-related.

| Tool | Required for | Install |
|---|---|---|
| git | All steps | Pre-installed on macOS; `sudo apt install git` on Ubuntu |
| Node.js ≥ 16 | CLI test suite | `brew install node` / `nvm install --lts` |
| Python 3 | `sprint-check` board | Pre-installed on macOS; `sudo apt install python3` on Ubuntu |
| Claude Code | Agent walkthrough only | `npm install -g @anthropic-ai/claude-code` |

**Verify nothing bleeds in from your host:**
- No `~/.claude/` directory yet (or it contains only what canon creates)
- No `~/.canon` directory

---

## 3. Install canon

### 3a — Published path (what real users hit)

```bash
curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash
```

This clones to `~/.canon` and runs `skills.sh init`. Use the curl path to validate the public installer.

Expected output: `Cloning canon → ~/.canon`, `Wiring agent hooks…`, then a `Done.` block with next steps. If prompted to add canon tools to PATH, answer `y`, then run the printed `source ~/.zshrc` or `source ~/.bashrc` command before using bare `skills.sh`, `sprint`, or `sprint-check`.

### 3b — Current branch (validates your pending changes)

```bash
git clone https://github.com/sunitghub/canon-skills.git ~/.canon
skills.sh init
```

Use 3b when you want to verify a branch before publishing. All paths should produce the same result.

**Verify install:**

```bash
ls ~/.canon/tools/skills.sh   # file exists
~/.canon/tools/skills.sh list # prints skill catalog before PATH is active
```

---

## 4. Automated test suite

Run the full suite against the installed clone:

```bash
cd ~/.canon
npm test
```

Expected: each of the seven test files prints `ok`, ending with `All tests passed.`

The suite covers: ticket lifecycle, sprint start/complete gate logic, `skills.sh add/refresh/status`, install-target resolution (both Node and bash paths), and the sprint-check server.

---

## 5. Project smoke test

Create a throwaway project and verify the CLI at a project level.

```bash
mkdir ~/test-project && cd ~/test-project
git init
~/.canon/tools/skills.sh add sprint
# Run the source command printed by the installer, for example:
# source ~/.zshrc  # or source ~/.bashrc
skills.sh status
```

Expected from `status`: all registered skills show `[ok]`, hooks listed as active.

```bash
sprint start "smoke test sprint"
```

Expected: prints `Sprint started: <id>`, creates `.tickets/<id>/ticket.md`, `DECISIONS.md`, `HANDOFF.md`.

```bash
sprint complete
```

Expected: blocked — `Missing required sprint file: .../acceptance.md`.

```bash
tkt ls
tkt show <id>
```

Expected: ticket visible, status `in_progress`.

```bash
tkt why .
```

Expected: reports no sprint history found (empty project, expected).

See the [skill verification table](setup.md#skill-verification) for expected responses per skill.

---

## 6. Board

```bash
cd ~/test-project
sprint-check
```

Expected: `sprint-check` starts (or joins) the shared Canon Cockpit server on
port 8899, browser opens to `http://127.0.0.1:8899/cockpit#open=<id>`, and the
project's tab loads showing the active ticket.

On headless Linux, the URL is printed instead of auto-opened. `curl -s http://127.0.0.1:8899/cockpit | grep -q "Canon Cockpit"` confirms the server responds.

---

## 7. Agent walkthrough (capstone)

**Requires:** Claude Code installed and authenticated (`claude login`).

This is the only step that validates the agent layer: `sprint start` producing a real brief, `sprint complete` running the wrapup pipeline, and the git-native pre-commit hook blocking before commit. The CLI suite above validates none of this.

Follow [examples/restaurant-bill-split/](../examples/restaurant-bill-split/README.md) end to end in your test project — give the agent its starting prompt and let it run a real sprint. Key things to confirm:

- `sprint start "..."` explicitly reads `HANDOFF.md` as its own context step (no hook — canon
  installs zero Claude Code hooks), then triggers tier selection, acceptance criteria, and a
  sprint brief before any code
- `capture` appends a discovery mid-sprint without prompting
- `sprint complete` blocks on unchecked acceptance items, then closes cleanly once all pass
- `wrapup`'s doc-refresh step explicitly updates `HANDOFF.md` at close (no hook)

---

## Windows 11

canon's CLI tools are bash scripts. The supported Windows 11 path is **Git for Windows (Git Bash) — no WSL required**: run **`install.cmd`** once (double-click it, or `install.cmd` from any terminal — it launches `install.ps1` without tripping PowerShell's execution policy) to add `tools/` to your user PATH, then use **Git Bash** to clone/update canon, and **PowerShell** for everything else. Each command has a `.cmd` wrapper, so run it by name: `sprint`, `tkt`, `skills` (for example `skills refresh`), and `canon` or `sprint-check-win` for the board. The board ships as a Go binary and settings are edited with Windows' built-in PowerShell, so no Python is needed. In a Git Bash window, use the script names instead (`skills.sh refresh`). See the [main setup guide](setup.md) and the README's **Windows 11 — no WSL required** section for the full steps.

#### Windows setup gotchas (real field errors + fixes)

Three errors have been seen on fresh Windows machines — each has a simple fix:

- **`install.ps1 is not digitally signed … UnauthorizedAccess`** — Windows' PowerShell
  execution policy blocking unsigned scripts. Fix: run **`install.cmd`** (batch is not subject
  to the policy), or invoke `powershell -ExecutionPolicy Bypass -File .\install.ps1` (a
  process-scoped bypass; no persistent system change). This is not a canon bug.
- **`WARNING: bash not found on PATH`** even though `where git` finds `git.exe` — Git for
  Windows adds `git.exe` (`C:\Program Files\Git\cmd`) to PATH but **not** `bash.exe`
  (`C:\Program Files\Git\bin`). Fix: run canon's CLI tools from the **Git Bash** terminal, or
  add `C:\Program Files\Git\bin` to your PATH. (Git is installed — bash is just not on PATH.)
- **`fatal: not a git repository (or any of the parent directories): .git`** — you're not
  inside a cloned canon folder (a downloaded/extracted zip has no `.git`). Fix: `git clone`
  canon into a folder and run `git`/`sprint`/`tkt` commands from **inside** that folder, not
  from your home directory.

**WSL2 with Ubuntu is an optional alternative** — use it only if you prefer a full Linux environment. Under WSL2 canon behaves exactly like the Linux/macOS path. The rest of this section documents that optional WSL2 route.

### WSL2 prerequisites

**1. Enable WSL2** (one-time, in PowerShell as administrator):

```powershell
wsl --install
```

This installs WSL2 and Ubuntu 22.04 by default. Reboot when prompted.

**2. Inside Ubuntu WSL2, install dependencies:**

```bash
sudo apt update && sudo apt install -y git python3 curl
# Node.js via nvm (apt version is often too old)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install --lts
```

**3. Optional — browser opening:**

```bash
sudo apt install -y wslu   # provides wslview, which sprint-check uses to open the board
```

Without `wslu`, sprint-check prints the URL instead of opening it automatically.

**Verify nothing bleeds in:**
- No `~/.claude/` directory yet
- No `~/.canon` directory

### Install

Same as the Linux path — run these inside the WSL2 terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash

# or from a specific branch
# git clone https://github.com/sunitghub/canon-skills.git ~/.canon && ~/.canon/tools/skills.sh init
```

If prompted to add canon tools to PATH, answer `y`, then run the printed
`source ~/.bashrc` command before using bare `skills.sh`, `sprint`, or
`sprint-check`.

### Test suite

```bash
cd ~/.canon && npm test
```

Expected: `All tests passed.`

### Project smoke test

Same commands as section 5 — run inside WSL2.

### Board

```bash
sprint-check
```

With `wslu` installed: browser opens via `wslview`. Without it, the URL is printed — open it manually in a Windows browser, or verify with:

```bash
curl -s http://127.0.0.1:8899/cockpit | grep -q "Canon Cockpit" && echo "board ok"
```

### Agent walkthrough

Claude Code runs inside WSL2. Install and authenticate there:

```bash
npm install -g @anthropic-ai/claude-code
claude login
```

Then follow the walkthrough exactly as on Linux/macOS — hooks, sprint flow, and board all behave identically.

## One-line install (t-8716, Windows VM with Git uninstalled, then restarted)

1. In PowerShell: `irm https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.ps1 | iex`. Pass when it explains Git Bash, prompts `[Y/n]`, warns about UAC, installs via winget, fetches canon, and prints `canon` as the next command.
2. Answer `n` on a second clean VM (or with winget unavailable): it stops with the download link and the re-run command, and `~\.canon` does not exist.
3. Re-run with `$env:CANON_YES=1`: no prompt, `~\.canon\cockpit` is kept, and the user PATH has one `tools\` entry.
4. From cmd: `curl.exe -fsSLO https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.cmd && install.cmd` does the same. Also try the read-first path: download `install.ps1`, open it, then `powershell -ExecutionPolicy Bypass -File .\install.ps1`. Record date, Windows build and outcome here, then run the non-git steps below.

**Result, 2026-09-30, Windows ARM64 VM, Git for Windows uninstalled and VM restarted** (run from branch `feat/t-8716`, `irm .../feat/t-8716/install.ps1 | iex`):
- Step 1 pass: explained Git Bash, `[Y/n]`, UAC, winget installed Git 2.55.0.5 (native ARM64), canon fetched, success line printed; `canon` then started Cockpit 0.3.0 with no Python.
- Step 3 pass: re-run skipped the Git prompt, kept `~\.canon\cockpit\keep.txt`, and left exactly one `~\.canon\tools` user PATH entry.
- Step 2 pass: answering `n` printed the download link and re-run command, kept the window open, and left no `~\.canon`.
- Step 4 pass (`install.cmd` via `curl.exe`, with the URL pointed at the branch since `main` had the old script): fetched `install.ps1`, ran the bootstrap to the success line. The read-first path and the non-git steps below are not run.
- Found: the download crawled with the default progress bar (fixed with `$ProgressPreference = "SilentlyContinue"`), and `Expand-Archive` showed its own slow progress bar (replaced with `ZipFile.ExtractToDirectory`).
- The one-liner and `install.cmd` only fetch the new script once this branch is on public `main`.

## Non-git project (t-5a4b, Windows VM; a plain folder with no .git)

Git for Windows stays installed (canon's tools need its bash); the folder is what has no git. Register a plain folder, click **+ sprint**, create a ticket, Start an agent, edit one file, create one and delete one, and watch the ticket's **Changes** panel. **Restore original files, end** lives in the End dialog of a **Scratch** session (Scratch button on the project card), not in a ticket session. Pass when the Changes panel and End dialog use plain words (no branch/commit/worktree/checkout vocabulary), restore puts the edited and deleted files back while the added one stays, and a case-variant or drive/UNC form of the registered folder does not register a second project.

**Result, 2026-09-30, Windows ARM64 VM, folder `Documents\MealSplit`:**
- `+ sprint` through the board worked (`Skills sprint`), New Ticket offered no worktree option, and the ticket's Changes panel listed `~ a.txt (+1 −1)`, `− b.txt`, `+ c.txt` with no git wording; canon's own files were not listed.
- Scratch End dialog: "This session changed 3 files" with Save as ticket / Keep changes, end / Restore original files, end. Restore put `a.txt` back and brought `b.txt` back; `c.txt` stayed, as the dialog says.
- A case-variant path (`c:\users\...\mealsplit`) gave "Project already registered."; the UNC form was refused with "Path does not exist." (the registration check failed before the daemon's "cwd not allowed" guard, which Go tests cover but the VM did not exercise).
- Found and fixed: the HANDOFF note said "in the main checkout" (now "in your folder") and the Add Project label said "absolute path to a git repo" (now "absolute path"). Not fixed: a ticket session has no Restore button (the endpoint exists, the page never calls it), and "Path does not exist." is shown for a UNC path that does exist.
- `a.txt` read `Original` after restore; restore copies the session-start snapshot byte for byte (covered by `TestEndScratchRestoreOriginalWithoutGit`), so the file most likely started with a capital O (the start-of-session text was not recorded separately).

---

## Pass criteria

| Check | Pass when |
|---|---|
| Install (3a) | `curl` prints `Done.`, `skills.sh list` works |
| Test suite (4) | `npm test` ends `All tests passed.` |
| Project wiring (5) | `skills.sh status` shows all `[ok]` |
| Sprint gate (5) | `sprint complete` blocks on missing files and unchecked items |
| Board (6) | Browser opens (or `curl` confirms server responds) |
| Agent walkthrough (7) | Sprint's own explicit context/refresh steps run (no hooks needed); sprint complete closes with all criteria checked |

Any failing check is a regression or a hidden dependency on your dev box.
