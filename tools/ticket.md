---
name: ticket
description: Bundled minimal ticket system (tkt) for creating, tracking, and closing tasks. Used by sprint and sprint-check.
category: tools
tags: [project-management, tasks, cli, git]
hidden: true
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
tkt close <id> [--no-sprint]  # mark closed (refuses without --no-sprint — directs to sprint complete if sprint docs exist, or to sprint start/--no-sprint otherwise)
tkt archive <id>              # mark archived (hidden from board, searchable)
tkt reopen <id>               # reopen
tkt ci <id> [on|off]          # mark CI-eligible for headless grading
tkt gate <id> [eval|full]     # headless gate mode: eval-only vs full (needs ci on)
tkt show <id>                 # show full ticket
```

## Sprint Artifacts

Core sprint-ticket artifacts (see `standards/ticket-layout.md` for the authoritative full field contract and doc lifecycle):

| File | Written by | Purpose |
|---|---|---|
| `ticket.md` | `sprint start` / `tkt` | Frontmatter + description |
| `acceptance.md` | agent at sprint start | Done criteria + test plan + QA |
| `plan.md` | agent at sprint start | Approach + decisions |
| `research.md` | agent at sprint start | Objective truth: relevant files, system model, constraints |
| `review-notes.md` | agent at sprint complete (normal+) | Advisory reviewer findings + verdict |
| `eval-report.md` | agent at sprint complete (normal+) | Adversarial per-criterion grades + verdict |
| `summary.md` | agent at sprint complete | Plan-vs-actual table + close prose |

`summary.md` appears as a **Summary** tab on the board — read-only once the
ticket is closed. It is the permanent record of what was delivered versus what
was planned.

## Closing Sprint Work

Use `sprint complete` for sprint work. It validates required sprint files and
acceptance checkboxes before closing the active ticket.

`tkt close <id>` on its own refuses to close: it directs you to `sprint complete`
if the ticket has sprint docs, or to `sprint start`/`--no-sprint` if it doesn't.
Genuinely doc-less/backlog tickets, or a sprint being deliberately abandoned
without completing it, close via the explicit `tkt close <id> --no-sprint`.

## Agent Workflow

- Before starting work: run `tkt ls` to understand open tasks.
- **When picking up a task: run `tkt start <id>` before writing any code.** This records `.tickets/ACTIVE` so agents agree on the current task.
- Include the ticket ID in every commit body (e.g. `Closes: t-8ms5`) per `standards/efficiency.md`'s Git conventions — type-prefixed subject, not a bare ticket-ID prefix.
- **Do not run `tkt close <id>` for sprint work.** Use `sprint complete` so
  validation runs consistently.
- Don't create tickets for trivial 1-line fixes. Use judgment.
- Prefer updating an existing ticket over creating a duplicate.

## Notes

- Ticket IDs appear in git log via the commit body's `Closes: t-xxxx` line.
- Priority: 0 = highest, 4 = lowest. Default is 2.
- `tkt` is bundled with canon in `tools/tkt` — no external install needed.
- Legacy flat `.tickets/<id>.md` tickets are kept readable for compatibility with older canon projects and simple external tooling. New canon tickets use `.tickets/<id>/ticket.md`.
