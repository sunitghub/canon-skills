---
name: ticket
description: Bundled minimal ticket system (tkt) for creating, tracking, and closing tasks. Used automatically by wrapup's approve workflow.
category: tools
tags: [project-management, tasks, cli, git]
---

# Ticket — Task Tracking

This project uses `tkt` for task management — a minimal ticket system bundled with canon.
New tickets are stored as `.tickets/<id>/ticket.md` with YAML frontmatter.
Legacy flat `.tickets/<id>.md` tickets remain readable.

## Getting Started

**Step 1 — Register this skill in your project:**
```bash
<path-to-canon>/skills.sh add ticket /path/to/your/project
```

The add command will offer to add `<canon>/tools` to your PATH so `tkt` is available everywhere.

**Step 2 — Use it:**
- **Claude**: "Create a ticket for the login bug" or "Show me open tickets" — Claude runs `tkt` commands automatically.
- **Codex**: Same natural language — Codex reads the skill from `AGENTS.md` and uses `tkt`.

No slash command needed. Just describe what you want to track.

## Key Commands

```bash
tkt create "title" [-t bug|feature|task|epic|chore] [-p 0-4] [-d "desc"]
tkt ls                        # list all tickets
tkt ls --status=in_progress   # filter by status
tkt start <id>                # mark in_progress
tkt current                   # show active ticket
tkt close <id>                # mark closed
tkt reopen <id>               # reopen
tkt show <id>                 # show full ticket
```

## Approve Workflow

**Trigger**: user says "approve", "approve `<id>`", "ship it", or equivalent after testing.

1. **Wrapup** — run `/wrapup` on all files modified since the ticket was started. All code modifications must happen before the ticket closes.
2. **Close ticket** — `tkt close <id>` only after wrapup completes.

## Agent Workflow

- Before starting work: run `tkt ls` to understand open tasks.
- **When picking up a task: run `tkt start <id>` before writing any code.** This records `.tickets/ACTIVE` so agents agree on the current task.
- Prepend the ticket ID to every commit message (e.g. `t-8ms5: add login rate limiter`).
- **Never run `tkt close <id>` directly.** Always use the approve workflow so wrapup runs consistently.
- Don't create tickets for trivial 1-line fixes. Use judgment.
- Prefer updating an existing ticket over creating a duplicate.

## Notes

- Ticket IDs appear in git log (e.g. `t-8ms5: add login rate limiter`).
- Priority: 0 = highest, 4 = lowest. Default is 2.
- `tkt` is bundled with canon in `tools/tkt` — no external install needed.
- For advanced features (dependency trees, linking, tags, assignees), install [ticket](https://github.com/wedow/ticket) (`brew install ticket`) — same `.tickets/` file format, fully compatible.
