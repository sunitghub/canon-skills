# 02 - Sprint Start

Ask your agent to start a focused sprint:

```text
Sprint start - build a simple Todo list with add, complete, delete, filters, local persistence, and tests.
```

The agent should run:

```bash
sprint start "Build a simple Todo list"
```

Expected files:

```text
.tickets/<id>/
  ticket.md
  blueprint.md
  acceptance.md
  plan.md
DECISIONS.md
HANDOFF.md
```

Before code changes, the agent should:

- Read `DECISIONS.md`, `HANDOFF.md`, and the sprint files.
- Map the small app structure under `src/` and `tests/`.
- Surface real gray areas, such as persistence location or filter behavior.
- Produce acceptance criteria and a test plan.
- Wait for approval before editing source.

For this example, a reasonable approval is:

```text
Use localStorage for persistence. Filters should be All, Open, and Done. Approved.
```
