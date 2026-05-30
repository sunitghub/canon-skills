# 05 - Sprint Complete

When implementation and tests are done, tell the agent:

```text
Sprint complete
```

The agent should:

- Run the wrapup pipeline where applicable.
- Verify each item in `.tickets/<id>/acceptance.md`.
- Confirm the test command passed.
- Update `DECISIONS.md` only for durable non-obvious decisions.
- Update `HANDOFF.md` with follow-up work.
- Run `sprint complete` to close the active ticket.

For this example, the close command should only succeed after the acceptance and test checkboxes are marked complete.
