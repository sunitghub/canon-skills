# AI-Skills

A personal library of skills, standards, and tool guides for AI coding agents.
Write a rule once — every agent in every project benefits.

## What's in here

| Path | What it is |
|------|-----------|
| `AGENTS.md` | Universal agent instructions (behavior, quality, output style) |
| `standards/` | Coding and git conventions — each file is a registerable skill |
| `tools/` | Usage guides for specific tools (e.g. ticket/tk) |
| `skills/` | Claude Code `SKILL.md` format for reusable slash commands |
| `supplements/` | Personal notes, cert prep, reference docs |
| `adapters/claude/` | Claude-specific `@`-import adapter |
| `skills.sh` | CLI to list, add, and remove skills per project |
| `CATALOG.md` | Static snapshot of all available skills |

---

## Agent Setup (one-time, per machine)

### Claude Code
Add to `~/.claude/CLAUDE.md`:
```
@~/Developer/AI-Skills/adapters/claude/CLAUDE.md
```
✓ Already done on this machine.

### Codex CLI
Add to `~/.codex/AGENTS.md`:
```
@/Users/<you>/Developer/AI-Skills/AGENTS.md
```
✓ Already done on this machine.

### Pi
Add to `~/.pi/agent/AGENTS.md` (create if missing):
```
@~/Developer/AI-Skills/AGENTS.md
```
Or symlink: `ln -s ~/Developer/AI-Skills/AGENTS.md ~/.pi/agent/AGENTS.md`

### Cursor
Create `.cursor/rules/ai-skills.mdc` in your project:
```
@~/Developer/AI-Skills/AGENTS.md
```

### Other agents (Aider, Continue, Windsurf, etc.)
Point their system prompt or rules config at `AGENTS.md` or the relevant skill file.
See each tool's docs for the exact config path.

---

## Per-project skill setup

### 1. See what's available
```bash
~/Developer/AI-Skills/skills.sh list
```

### 2. Register skills into a project
```bash
# Run from inside the project, or pass the path
~/Developer/AI-Skills/skills.sh add ticket
~/Developer/AI-Skills/skills.sh add git
~/Developer/AI-Skills/skills.sh add general

# Or with explicit path:
~/Developer/AI-Skills/skills.sh add ticket ~/Developer/react-admin
```

`add` writes to:
- **`CLAUDE.md`** — `@`-imports for Claude Code
- **`AGENTS.md`** — managed skill block for Codex, Pi, and others

### 3. Check what's registered
```bash
~/Developer/AI-Skills/skills.sh status
```

### 4. Remove a skill
```bash
~/Developer/AI-Skills/skills.sh remove ticket
```

---

## Adding a new skill

1. Create a `.md` file in `standards/` or `tools/` with YAML frontmatter:
```markdown
---
name: your-skill
description: One-line description shown in skills.sh list
category: standards   # or: tools
tags: [tag1, tag2]
---

# Your Skill Title
...content...
```

2. It immediately appears in `skills.sh list` — no registration needed.

3. Update `CATALOG.md`:
```bash
cd ~/Developer/AI-Skills
{ echo "# AI-Skills Catalog"; echo ""; echo "> Auto-generated snapshot. Run \`skills.sh list\` for live output."; echo ""; echo "\`\`\`"; ./skills.sh list; echo "\`\`\`"; } > CATALOG.md
```
