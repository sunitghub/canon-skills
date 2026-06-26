# 03 - Sprint Check

Type this in the command line from the walkthrough root:

```bash
sprint-check
```

Use the board as the shared checkpoint between developer, agent, and reviewer.
It reads local files only: `.tickets/` for sprint state, `HANDOFF.md` for current
focus, and `git log` for recent commits. Nothing here requires an account or a
remote service.

This is where Layer 1 becomes visible. `HANDOFF.md` gives the board its Current
Focus, so a reviewer or fresh agent can see what is underway before reading the
whole ticket.

If the project already has tickets, they add useful context without replacing
`HANDOFF.md`. On resume, start with the active ticket, open tickets, and the
sidebar focus. Read closed tickets only when they are recent, related to the same
files, or linked from commits you are about to touch. That keeps continuity
useful without spending the whole context window on old work.

## Board States To Check

Reload the board at each stage and confirm:

1. Before `sprint start`, the board is empty.
2. After `sprint start`, the ticket is In Progress and not ready.
3. `acceptance.md` and `plan.md` appear as tabs once they exist. Acceptance
   criteria stay unchecked until the behavior is implemented and verified.
4. After tests pass and acceptance is checked, `sprint complete` moves the ticket
   to Done.

## Readiness Indicators

Every card has a readiness label:

- `needs acc` — add `acceptance.md`.
- `needs plan` — add `plan.md`.
- `incomplete` — Acceptance exists, but `## Criteria` or `## Test Plan` has no
  checklist items.
- `plan incomplete` — Plan exists, but `## Approach` is empty or still contains
  the template placeholder.
- `ready` — Acceptance and Plan exist with useful content.

Click or hover the readiness label to see the popover. These warnings are early
signals; `sprint complete` still performs the final gate.

## Ticket Detail And Inline Docs

Click the Todo ticket. The detail modal shows:

- Status, type, priority, age, and readiness.
- The ticket description.
- The two sprint docs: `Acceptance` and `Plan`.
- An `Edit` button for changing the active doc in place.

The **Plan** tab generates jump links from `##` headings in document order.
`## Sign-off` is always the first heading, so it appears as the first link in
the sticky nav — the approval state is visible before you scroll to `## Approach`.

Use inline editing for small corrections, such as tightening a criterion or
checking off a verified test. The editor keeps required headings and the ticket
line intact. If both sprint docs already exist, `+ New doc` is hidden because
Canon's sprint flow uses only Acceptance and Plan.

Closed or discarded tickets are read-only. You can still inspect their docs, but
you cannot edit them without reopening or creating new work.

## Search

Use the search box above the columns to find tickets by title, id, status, type,
priority, description, doc names, or readiness labels.

Try:

```text
plan incomplete
```

A ticket whose Plan still contains placeholder approach text should remain
visible. Clear the search or press `Esc` to restore the full board. Matching
tickets stay in their original lanes so status context is not lost.

Switch the mode from `Search` to `Why` when you want code archaeology instead of
ticket filtering. Enter a file path, and sprint-check shows the tickets and Plan
decisions that explain commits touching that file. You can also type
`why:path/to/file` in the input.

## Status And Workflow Actions

Dragging a card between columns updates the ticket's status in `.tickets/`.
This is useful for ordinary state changes, but it is not a replacement for the
close command.

Two important boundaries:

- Moving a card to Done changes ticket state only; it does not run the
  `sprint complete` pipeline.
- `Discard ticket` is for abandoned or no-longer-needed work; it moves the
  ticket to Discarded, not Done.

Use `+ New ticket` when you discover separate follow-up work during the Todo
walkthrough. Keep the current ticket focused instead of expanding scope.

**Handing a board-created ticket to the agent.** If you spot a bug or follow-up
and create it directly on the board — filling in the title and description there
— hand it to the agent with the ticket id:

```text
sprint start t-xxxx
```

The agent reads the ticket you created, drafts `acceptance.md` and `plan.md`
from the details you provided, grills you on any gray areas, and waits for your
approval before writing any code. The flow is identical to `sprint start "..."`;
the only difference is the ticket already exists.

## Sidebar And Commits

The sidebar shows the active sprint, current git branch/state, current focus,
recent commits, and ticket counts. After you commit implementation work, click a
recent commit to inspect changed files and ticket association. Commit messages
that include the ticket id are easiest for the board to connect.

If the session ends midway through the Todo app, `HANDOFF.md` should say what is
in progress and what to do next. Reloading `sprint-check` after a fresh session
should show that continuity in the sidebar.

Stop the board with `Ctrl+C` in the terminal.

---

**Next → [04-implementation.md](04-implementation.md)**
