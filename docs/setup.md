# Canon Setup

> **Windows 11:** canon's CLI tools require WSL2 (Ubuntu). Run all commands below inside the WSL2 terminal. See [fresh-machine-test.md → Windows 11](fresh-machine-test.md#windows-11-wsl2) for the full setup path.

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

Wires handoff + quality hooks into `~/.claude/settings.json` (Claude Code) and copies the Pi handoff extension when Pi is installed. Re-run if you move the canon folder.

**Step 3 — Register sprint in your project**

```bash
cd /path/to/your-project
~/.canon/tools/skills.sh add sprint
```

If prompted to add canon tools to PATH, answer `y`, then run the printed `source ~/.zshrc` or `source ~/.bashrc`. Verify with `skills.sh status`.

`add sprint` pulls in the full workflow dependency stack automatically. Most projects need nothing else. `skills.sh addall` registers every standalone skill.

**Uninstall**

```bash
skills.sh uninstall
rm -rf ~/.canon
```

Removes canon hook entries from `~/.claude/settings.json`, the Pi handoff extension, and `~/.config/canon/install_path`. If the install folder was already deleted, re-clone to the same path before running uninstall.

## Session hooks

Two hooks fire automatically — no invocation needed:

| Hook | Fires when | What it does |
|------|------------|--------------|
| `handoff-inject` | First message of a session (4h window) | Injects `HANDOFF.md` into context — agent wakes up knowing project state |
| `auto-handoff` | Session end, when uncommitted changes exist | Appends timestamped git-state snapshot to `HANDOFF.md` |

Keep `HANDOFF.md` under 80 lines. Prune stale entries freely — git history preserves everything.

## Skill lifecycle

Order of operations for any new or edited skill:

```
Write SKILL.md
      ↓
./tools/canon-dev.sh lint     ← structure valid? (frontmatter, one-job, progressive disclosure)
      ↓
Write evals/evals.json        ← ≥3 cases: control + at least 2 other case types
      ↓
/skill-eval <name>            ← behavior correct? (executor + grader subagents)
      ↓
skills.sh add <name>          ← register for use
```

Fix lint failures before writing evals — a malformed skill may pass evals accidentally. If evals fail, fix the skill body, not the expectations (unless the expectation itself was wrong).

Run evals before editing an existing skill to record a baseline pass rate. Keep the change only if pass rate holds or improves.

## Reference

### Skills commands

```bash
skills.sh list                    # show available skills
skills.sh add sprint              # register a skill in current project
skills.sh addall                  # register all standalone skills
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

Hook scripts update immediately — called by path. Skill content updates automatically via symlinks (`.claude/skills → ~/.canon/skills`) — every project picks up changes on the next session.

To repair symlinks after an upgrade:

```bash
skills.sh refresh /path/to/your-project
```
