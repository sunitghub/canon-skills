# AI-Skills

Shared skills, standards, and prompts for AI coding agents.
Single source of truth — write once, all agents benefit.

## Structure

```
AI-Skills/
├── AGENTS.md                    # Universal entry point
├── standards/
│   ├── general.md               # Language-agnostic coding principles
│   └── git.md                   # Commit, branch, PR conventions
├── skills/                      # Claude Code SKILL.md format
├── supplements/
│   └── claude-architect/        # Cert prep notes and extra references
└── adapters/
    └── claude/
        └── CLAUDE.md            # @-imports for Claude Code
```

## Per-Agent Wiring

### Claude Code
Add one line to `~/.claude/CLAUDE.md`:
```
@~/Developer/AI-Skills/adapters/claude/CLAUDE.md
```

### Pi
Symlink or reference in `~/.pi/agent/AGENTS.md`:
```bash
ln -s ~/Developer/AI-Skills/AGENTS.md ~/.pi/agent/AGENTS.md
```
Or add to an existing `~/.pi/agent/AGENTS.md`:
```
@~/Developer/AI-Skills/AGENTS.md
```

### Codex CLI
Symlink `AGENTS.md` into any project root:
```bash
ln -s ~/Developer/AI-Skills/AGENTS.md ./AGENTS.md
```

## Adding Content

- **New standard**: Add a `.md` to `standards/`, reference it from `AGENTS.md`.
- **New skill (Claude)**: Add `skills/[name]/SKILL.md`.
- **Cert/supplement notes**: Drop into `supplements/claude-architect/`.
- Keep `AGENTS.md` under ~150 lines — focused on behavior, not documentation.
