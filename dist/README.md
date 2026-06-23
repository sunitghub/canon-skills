# Canon Workshop — Quick Install

Canon is a sprint workflow harness: one CLI for tickets, one for the board, and a local kanban that runs entirely on your machine.

## Install

### macOS / Linux

```bash
bash install.sh
```

### Windows — Git Bash

Open Git Bash (comes with Git for Windows) and run:

```bash
bash install.sh
```

### Windows — PowerShell

```powershell
.\install.ps1
```

> If PowerShell blocks the script, run this first:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

---

## What Gets Installed

Everything goes into `~/.canon` (or `%USERPROFILE%\.canon` on Windows):

| Path | What it is |
|---|---|
| `tools/sprint` | Sprint CLI — creates tickets, starts/closes sprints |
| `tools/sprint-check` | Board server — opens the kanban in your browser |
| `tools/tkt` | Ticket CLI — create, list, update tickets |
| `skills/sprint/` | Sprint skill loaded by Claude Code |
| `standards/` | Agent coding standards |
| `AGENTS.md` | Universal agent instructions |

## Add to PATH

**macOS / Linux** — add to `~/.zshrc` or `~/.bashrc`:

```bash
export PATH="$PATH:$HOME/.canon/tools"
```

**Windows PowerShell** — add to your profile (`notepad $PROFILE`):

```powershell
$env:PATH += ";$HOME\.canon\tools"
```

## Verify

```bash
tkt ls
sprint-check   # opens http://localhost:8423 in your browser
```

## Workshop Commands

```bash
# Create a ticket
tkt create "my first ticket" -t task

# Start a sprint
sprint start "my first ticket"

# Open the board
sprint-check
```
