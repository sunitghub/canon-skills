---
name: sprint-check
description: Local kanban dashboard for the current project — reads .tickets/, HANDOFF.md, and git log. Zero install beyond the canon repo.
category: tools
tags: [project-management, kanban, dashboard, gui]
---

# sprint-check — Local Kanban Dashboard

A browser-based kanban board that reads the current project's tickets, HANDOFF.md, and git history. No cloud, no login, no install beyond canon.

![sprint-check board](sprint-check/screenshot.png)

## Getting Started

**Step 1 — Register the skill** (adds `canon/tools` to your PATH if needed):
```bash
<path-to-canon>/skills.sh add sprint-check /path/to/your/project
```

**Step 2 — Launch from your project:**
```bash
sprint-check.sh
```

The board opens in your default browser at `http://127.0.0.1:<port>`. Press `Ctrl+C` to stop.

## Board

Four columns map directly to tkt statuses:

| Column | tkt status |
|--------|-----------|
| Open | `open` |
| In Progress | `in_progress` |
| Done | `closed` |
| Discarded | `cancelled` |

**Cards** show ticket ID, type badge, title, priority dots, age, and a readiness indicator:
- `● ready` (green) — has description + at least one doc
- `● needs desc` / `● needs docs` / `● not ready` (gray) — what's missing

Click the readiness indicator for a checklist popover. Click anywhere else on the card to open the full ticket.

**Moving tickets:**
- Drag and drop between columns
- Or open the ticket and use `← Back` / `Forward →` buttons
- Keyboard: `←` / `→` to move, `Esc` to close

**Column count badge** is hidden when a column is empty.

## Sidebar

- **Now Working On** — `in_progress` tickets highlighted in accent color; click to open, or hit `copy` to copy the commit prefix (`t-xxxx: `) to clipboard
- **Git** — current branch + modified file count
- **Current Focus** — `## Current Focus` section from HANDOFF.md
- **Recent Commits** — last 5 commits (click any to see full message, changed files, and related tickets)
- **Tickets** — count summary by status

Collapse/expand the sidebar with the `‹` toggle. Width is remembered across sessions.

## Ticket Modal

Click any card to open its detail view:

- **Meta row** — Status, Type, Priority, Age, Ready indicator
- **Tabs** — Description tab appears only when companion docs exist; otherwise body is shown directly
- **Docs** — Blueprint, Decisions, QA, Notes (or any custom doc) as tabs; click `+ New doc` to create one with a template
- **Edit** — inline edit for the ticket body or any doc; Save / Cancel
- **Footer** — `← Back`, `Forward →`, `Discard ×`; keyboard hints bottom-right

## New Ticket

Click `+ New ticket` in the header. As you type the title, the type (Feature / Task / Bug / etc.) is detected automatically. Select type and priority, write a description, and submit — the ticket lands in Open.

## Agent Workflow

- Use sprint-check to get your bearings at session start: "open sprint-check and tell me what's in progress"
- Agents read sprint-check for context; status changes happen via `tkt` commands
- The **Now Working On** strip + `copy` button makes it easy to prefix commits with the active ticket ID
- A green readiness dot signals a ticket has enough context for the agent to act on it without asking for clarification

## Notes

- Refreshes automatically every 8 seconds
- Dark/light mode toggle in the header — preference persisted in localStorage
- Runs on macOS, Linux, and WSL — Python 3 stdlib only, no pip required
- Port defaults to 8423, increments automatically if busy
