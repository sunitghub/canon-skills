# Canon Setup

> **Windows 11 — no WSL required:** install [Git for Windows](https://git-scm.com/download/win), then:
> 1. Run **`install.cmd`** once (double-click it, or run `install.cmd` from any terminal) — it launches `install.ps1` for you and adds `tools/` to your user PATH. Running `install.ps1` directly can fail with *"not digitally signed … UnauthorizedAccess"* (Windows' PowerShell execution policy blocking unsigned scripts); `install.cmd` sidesteps it with a process-scoped bypass, or run `powershell -ExecutionPolicy Bypass -File .\install.ps1` manually.
> 2. Use **Git Bash** to clone canon and run `git pull` to stay updated.
> 3. Use **PowerShell** for everything else: `sprint-check-win` opens the board; create and manage tickets through the UI.
>
> For agent-driven workflows (`sprint`, `tkt`, `skills.sh`), run those commands from Git Bash. WSL2 also works — see [fresh-machine-test.md → Windows 11](fresh-machine-test.md#windows-11).

## Install

**Step 1 — Clone canon**

Use the one-line installer from the [README](https://github.com/sunitghub/canon-skills#canon), or clone manually:

```bash
git clone https://github.com/sunitghub/canon-skills.git ~/.canon
```

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

**Uninstall**

```bash
skills.sh uninstall
rm -rf ~/.canon
```

Removes the git-native `.git/hooks/pre-commit` entry it installed, the Pi handoff extension, and `~/.config/canon/install_path`. If the install folder was already deleted, re-clone to the same path before running uninstall.

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
| `context-check` | `/context-check` | Context audit; findings appended to context-findings.md |
| `doc-audit` | `/doc-audit` | README/guides audit; findings appended to doc-findings.md |
| `output-validator` | `/output-validator` | Pre/post-generation report validation |
| `skill-export` | `skill-export <name>` | Exports flat skill as paste-ready text |

## Staying updated

```bash
cd ~/.canon && git pull
```

Hook scripts update immediately — called by path. Skill content updates automatically via symlinks (`.claude/skills → ~/.canon/skills` and `.agents/skills → ~/.canon/skills`, for Codex/Pi) — every project picks up changes on the next session.

To repair symlinks after an upgrade:

```bash
skills.sh refresh /path/to/your-project
```
