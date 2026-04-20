---
name: ticket
description: TK is CLI ticket system for task management. Run `tk help` when you need to use it.
category: tools
tags: [project-management, tasks, cli, git]
---

# Ticket — Git-Native Task Tracking

This project uses [ticket](https://github.com/wedow/ticket) (`tk`) for task management.
Tickets are markdown files with YAML frontmatter stored in `.tickets/`.

## Getting Started

**Step 1 — Install `tk` on your machine** (one-time):
```bash
brew tap wedow/tools
brew install ticket
```

**Step 2 — Register this skill in your project:**
```bash
~/Developer/AI-Skills/skills.sh add ticket /path/to/your/project
```

**Step 3 — Verify:**
```bash
~/Developer/AI-Skills/skills.sh status /path/to/your/project
```

**Step 4 — Use it:**
- **Claude**: "Create a ticket for the login bug" or "Show me open tickets" — Claude runs `tk` commands automatically.
- **Codex**: Same natural language — Codex reads the skill from `AGENTS.md` and uses `tk`.

No slash command needed. Just describe what you want to track.

## Installation (required before use)

```bash
brew tap wedow/tools
brew install ticket
```

Verify: `tk help`

## Key Commands

```bash
tk create "title" [-t bug|feature|task|epic|chore] [-p 0-4] [-d "desc"]
tk ls                          # list open tickets
tk ls --status=in_progress     # filter by status
tk start <id>                  # mark in_progress
tk close <id>                  # mark closed
tk reopen <id>                 # reopen
tk show <id>                   # show full ticket
tk dep <id> <dep-id>           # add dependency (id depends on dep-id)
tk dep tree <id>               # show dependency tree
tk dep cycle                   # find dependency cycles
```

## Agent Workflow

- Before starting work: run `tk ls` to understand open tasks.
- When picking up a task: run `tk start <id>`.
- When creating sub-tasks: use `--parent <id>` to link them.
- When done: run `tk close <id>`.
- Don't create tickets for trivial 1-line fixes. Use judgment.
- Prefer updating an existing ticket over creating a duplicate.

## Notes

- Ticket IDs appear in git log (e.g. `nw-5c46: add SSE connection`). You can click them in VS Code.
- Use `tk dep cycle` before closing a milestone to catch blocked chains.
- Priority: 0 = highest, 4 = lowest. Default is 2.
