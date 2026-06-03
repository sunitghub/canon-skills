# 03 - Sprint Check

Type this in the command line from the walkthrough root:

```bash
sprint-check
```

Use this page as a visual checkpoint. Reload the board at each stage and confirm:

1. Before `sprint start`, the board is empty.
2. After `sprint start`, the ticket is In Progress and `not ready`, and
   `ticket.md` exists.
3. `acceptance.md` and `blueprint.md` appear as tabs once the agent drafts them;
   `plan.md` appears only after you approve. Acceptance criteria stay unchecked
   until the behavior is implemented and verified.
4. After tests pass and acceptance is checked, `sprint complete` moves the
   ticket to Done.

The board reads `.tickets/` for sprint state, `HANDOFF.md` for current focus,
and `git log` for recent commits. The detail view shows the same sprint files
the agent is using, and the sidebar shows current git state.

Two things the board does **not** do:

- Moving a card changes ticket state only — it does not run the
  `sprint complete` pipeline, so never drag a ticket to Done as a substitute.
- `Discard ticket` is for abandoned or no-longer-needed work; it moves the
  ticket to the Discarded column, not Done.

Stop it with `Ctrl+C` in the terminal.
