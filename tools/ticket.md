---
name: ticket
description: Bundled minimal ticket system (tkt) for creating, tracking, and closing tasks. Used by sprint and sprint-check.
category: tools
tags: [project-management, tasks, cli, git]
---

# Ticket — Task Tracking

This project uses `tkt` for task management — a minimal ticket system bundled with canon.
New tickets are stored as `.tickets/<id>/ticket.md` with YAML frontmatter.
Legacy flat `.tickets/<id>.md` tickets remain readable.

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

## Sprint Artifacts

Canonical layout for a sprint ticket:

| File | Written by | Purpose |
|---|---|---|
| `ticket.md` | `sprint start` / `tkt` | Frontmatter + description |
| `acceptance.md` | agent at sprint start | Done criteria + test plan |
| `plan.md` | agent at sprint start | Approach + decisions |
| `summary.md` | agent at sprint complete | Plan-vs-actual table + close prose |

`summary.md` appears as a **Summary** tab on the board — read-only once the
ticket is closed. It is the permanent record of what was delivered versus what
was planned.

## Closing Sprint Work

Use `sprint complete` for sprint work. It validates required sprint files and
acceptance checkboxes before closing the active ticket.

## Agent Workflow

- Before starting work: run `tkt ls` to understand open tasks.
- **When picking up a task: run `tkt start <id>` before writing any code.** This records `.tickets/ACTIVE` so agents agree on the current task.
- Prepend the ticket ID to every commit message (e.g. `t-8ms5: add login rate limiter`).
- **Do not run `tkt close <id>` for sprint work.** Use `sprint complete` so
  validation runs consistently.
- Don't create tickets for trivial 1-line fixes. Use judgment.
- Prefer updating an existing ticket over creating a duplicate.

## Notes

- Ticket IDs appear in git log (e.g. `t-8ms5: add login rate limiter`).
- Priority: 0 = highest, 4 = lowest. Default is 2.
- `tkt` is bundled with canon in `tools/tkt` — no external install needed.
- Legacy flat `.tickets/<id>.md` tickets are kept readable for compatibility with older canon projects and simple external tooling. New canon tickets use `.tickets/<id>/ticket.md`.
