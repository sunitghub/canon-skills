# Fresh Machine Test

Validates that canon is self-contained and works on a machine where none of your dev-box config exists. Uses a UTM virtual machine.

**What this proves:** canon installs, wires hooks, runs its CLI suite, and shows the board — with no help from your global dotfiles, Homebrew setup, or pre-existing `~/.claude` config.

---

## 1. Guest OS

**Recommended: macOS** — the only guest type that surfaces hidden global-config dependencies. UTM supports macOS Sequoia/Sonoma on Apple Silicon via IPSW restore images.

**Linux alternative: Ubuntu 22.04 Desktop ARM64** (UTM gallery) — fast to spin up, exercises the Linux-path fallbacks (`xdg-open`, `ss`) but won't catch macOS-specific config drift. Use for portability checks, not the primary validation.

Headless (server) Linux is sufficient for the CLI suite and install tests, but **not** the board step, which requires a browser.

**Windows 11 developers:** canon's CLI tools are bash scripts — they require WSL2. See [Windows 11 (WSL2)](#windows-11-wsl2) below. The UTM Windows 11 ARM64 image lets you test the Windows path on your Mac.

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

Expected: Python server starts on port 8423, browser opens to `http://127.0.0.1:8423`, board loads showing the active ticket.

On headless Linux, the URL is printed instead of auto-opened. `curl -s http://127.0.0.1:8423 | grep -q sprint-check` confirms the server responds.

---

## 7. Agent walkthrough (capstone)

**Requires:** Claude Code installed and authenticated (`claude login`).

This is the only step that validates the agent layer: hooks firing, `sprint start` producing a real brief, `sprint complete` running the wrapup pipeline. The CLI suite above validates none of this.

Follow [examples/canon-todo-walkthrough/](../examples/canon-todo-walkthrough/README.md) end to end in your test project. Key things to confirm:

- `handoff-inject` fires on session start (HANDOFF.md appears in first prompt silently)
- `sprint start "..."` triggers tier selection, acceptance criteria, and a sprint brief before any code
- `capture` appends a discovery mid-sprint without prompting
- `sprint complete` blocks on unchecked acceptance items, then closes cleanly once all pass
- `auto-handoff` updates HANDOFF.md on session end

---

## Windows 11 (WSL2)

canon's CLI tools are bash scripts. On Windows 11 the supported path is **WSL2 with Ubuntu** — not Git Bash, not PowerShell.

### Prerequisites

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
curl -s http://127.0.0.1:8423 | grep -q sprint-check && echo "board ok"
```

### Agent walkthrough

Claude Code runs inside WSL2. Install and authenticate there:

```bash
npm install -g @anthropic-ai/claude-code
claude login
```

Then follow the walkthrough exactly as on Linux/macOS — hooks, sprint flow, and board all behave identically.

---

## Pass criteria

| Check | Pass when |
|---|---|
| Install (3a) | `curl` prints `Done.`, `skills.sh list` works |
| Test suite (4) | `npm test` ends `All tests passed.` |
| Project wiring (5) | `skills.sh status` shows all `[ok]` |
| Sprint gate (5) | `sprint complete` blocks on missing files and unchecked items |
| Board (6) | Browser opens (or `curl` confirms server responds) |
| Agent walkthrough (7) | All hooks fire; sprint complete closes with all criteria checked |

Any failing check is a regression or a hidden dependency on your dev box.
