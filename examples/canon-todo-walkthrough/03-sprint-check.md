# 03 - Sprint Check

Type this in the command line from the walkthrough root:

```bash
sprint-check
```

Use this page as a visual checkpoint during the walkthrough:

1. Before `sprint start`, the board is empty.
2. After `sprint start`, the ticket is In Progress and `not ready`.
3. After `Acceptance`, `Blueprint`, and `Plan` are created, the docs appear as
   tabs.
4. After tests pass and acceptance is checked, `sprint complete` moves the
   ticket to Done.

The board is for visibility and local ticket edits. Creating a ticket or moving
a card changes ticket state only; it does not run the `sprint complete`
pipeline.

The board reads:

- `.tickets/` for sprint state.
- `HANDOFF.md` for current focus and next steps.
- `git log` for recent commits.

Use it to confirm:

- The Todo ticket starts In Progress and not ready.
- `ticket.md` exists from `sprint start`.
- `acceptance.md`, `blueprint.md`, and `plan.md` appear only after you create
  them with `+ New doc`.
- Acceptance criteria remain unchecked until the behavior is implemented and
  verified.
- The sidebar shows current git state.
- The ticket detail view contains the same sprint files the agent is using.
- Do not drag the ticket to Done as a substitute for `sprint complete`.
- Use `Discard ticket` only when the work is abandoned or no longer needed. It
  moves the ticket to the Discarded column instead of Done.

Stop it with `Ctrl+C` in the terminal.
