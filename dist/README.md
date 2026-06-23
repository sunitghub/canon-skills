# Canon Workshop — Windows 11 + VS Code

This zip contains everything needed for the workshop: canon tools, sprint skills,
the local `sprint-check` board, the Todo walkthrough, and the finished Todo
reference app.

Windows workshop goal: **no WSL and no Python install**. Git for Windows is the
only shell prerequisite. Node.js is needed for the Todo app tests and local
browser server.

## Prerequisites

Windows 11:

- VS Code
- Git for Windows
- Node.js LTS

macOS / Linux:

- Bash
- Python 3 for the default `sprint-check` server
- Node.js LTS for the Todo app

## Install On Windows

1. Extract `canon-workshop.zip`.
2. Open the extracted `canon` folder in VS Code.
3. Open a VS Code PowerShell terminal.
4. Run:

```powershell
.\install.ps1
```

If PowerShell blocks the script, run this once and retry:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Close and reopen the VS Code terminal after install so PATH refreshes.

Verify:

```powershell
tkt ls
sprint --help
sprint-check --help
skills list
```

Expected: all four commands run from PowerShell. `sprint-check` uses the bundled
Windows `sprint-check.exe`; it should not ask for Python.

## Install On macOS / Linux

From the extracted `canon` folder:

```bash
bash install.sh
export PATH="$PATH:$HOME/.canon/tools"
```

Open a new terminal or source your shell profile if you make the PATH change
permanent.

## Copy The Todo Walkthrough

Windows PowerShell:

```powershell
$dest = "$HOME\canon-todo-walkthrough"
Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
Copy-Item -Recurse "$HOME\.canon\examples\canon-todo-walkthrough" $dest
cd $dest
skills add sprint
```

macOS / Linux / Git Bash:

```bash
~/.canon/scripts/copy-todo-walkthrough.sh ~/canon-todo-walkthrough
cd ~/canon-todo-walkthrough
skills.sh add sprint
```

Then open the board:

```powershell
sprint-check
```

Stop the board with `Ctrl+C` in the terminal.

## Workshop Flow

From the walkthrough folder:

```powershell
sprint start "Build a simple Todo list"
sprint-check
```

Then follow:

```text
README.md
steps/02-sprint-start.md
steps/03-sprint-check.md
steps/04-implementation.md
steps/05-sprint-complete.md
```

## Todo Reference App

The finished reference app is installed at:

```text
~/.canon/examples/todo-app
```

Windows PowerShell:

```powershell
cd "$HOME\.canon\examples\todo-app"
npm test
npm run serve
```

macOS / Linux:

```bash
cd ~/.canon/examples/todo-app
npm test
npm run serve
```

Open `http://127.0.0.1:4173`. The server uses Node, not Python.

## Installed Contents

Everything installs to `~/.canon` or `%USERPROFILE%\.canon`.

| Path | Purpose |
|---|---|
| `tools/tkt` + `tools/tkt.cmd` | Ticket CLI |
| `tools/sprint` + `tools/sprint.cmd` | Sprint CLI |
| `tools/skills.sh` + `tools/skills.cmd` | Project wiring CLI |
| `tools/sprint-check` | macOS/Linux board launcher |
| `tools/sprint-check.exe` | Windows board server, no Python required |
| `examples/canon-todo-walkthrough/` | Workshop walkthrough |
| `examples/todo-app/` | Finished Todo reference implementation |
| `skills/` | Canon skills |
| `standards/` | Agent coding standards |

## Troubleshooting

- `tkt` or `sprint-check` not found: close and reopen the VS Code terminal.
- `skills add sprint` says Git Bash is missing: reinstall Git for Windows and
  make sure `bash.exe` is available, or use the default Git installer settings.
- PowerShell blocks `install.ps1`: run
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
- `npm test` fails because `npm` is missing: install Node.js LTS.
