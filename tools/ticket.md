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
<path-to-canon>/skills.sh add ticket /path/to/your/project
```

**Step 3 — Verify:**
```bash
<path-to-canon>/skills.sh status /path/to/your/project
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

## Approve Workflow

**Trigger**: user says "approve", "approve `<id>`", "ship it", or equivalent after testing.

This replaces manually asking to close, clean up, and review — one phrase covers the full pipeline:

1. **Pre-flight** — run `tk dep cycle`. Abort if cycles are detected.
2. **Walk the tree** — run `tk dep tree <id>`. Close all dependencies bottom-up (leaves first, then parents). The user only ever specifies the root — never list deps manually.
3. **Wrapup** — run `/wrapup` on all files modified since the ticket was started. All code modifications must happen before the ticket closes.
4. **Close ticket** — `tk close <id>` only after wrapup completes.

## Agent Workflow

- Before starting work: run `tk ls` to understand open tasks.
- **When picking up a task: run `tk start <id>` before writing any code.** Never skip this — tickets must reflect actual state.
- When creating sub-tasks: use `--parent <id>` to link them.
- Prepend the ticket ID to every commit message (e.g. `nw-5c46: add SSE connection`).
- **Never run `tk close <id>` directly.** Always use the approve workflow so wrapup runs consistently.
- Don't create tickets for trivial 1-line fixes. Use judgment.
- Prefer updating an existing ticket over creating a duplicate.

## Notes

- Ticket IDs appear in git log (e.g. `nw-5c46: add SSE connection`). You can click them in VS Code.
- Priority: 0 = highest, 4 = lowest. Default is 2.
