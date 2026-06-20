---
name: handoff
description: Session context handoff protocol using repo-local HANDOFF.md
category: tools
tags: [handoff, context, memory, agents]
hidden: true
---

# Handoff

Keep `HANDOFF.md` current enough that a new Claude, Codex, or Pi session can
resume without re-explaining the work.

## When to Read

- At session start
- After context reset or compaction
- Before `sprint complete`
- When switching agents

## When to Write

- Work stops with uncommitted changes
- Current focus changes materially
- A non-obvious discovery should survive the session
- Follow-up work remains after wrapup

## When to Prune

HANDOFF.md is working memory, not a changelog. Prune entries that no longer
help the next agent act:

- **Current Focus** — retire entries older than ~2 sprints with no active work;
  condense into a single context sentence if still relevant
- **In Progress** — remove tickets that have been closed or stalled for weeks
  without movement
- **Discoveries** — drop entries the next agent can derive from reading the code

When in doubt: if an entry wouldn't change how the next session starts, cut it.

## Format

```markdown
# Handoff

## Current Focus
One sentence.

## In Progress
- Ticket or file path — current state

## Discoveries
- **YYYY-MM-DD** Discovery - how to apply it

## Next Steps
1. Concrete next action
```

Keep it short. Prefer bullets that help the next agent act. Do not duplicate
the git diff, ticket body, or obvious code facts. Decisions belong in
`DECISIONS.md` — do not restate them here.

