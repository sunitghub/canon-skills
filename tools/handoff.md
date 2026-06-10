---
name: handoff
description: Session context handoff protocol using repo-local HANDOFF.md
category: tools
tags: [handoff, context, memory, agents]
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

## Automation

`skills.sh init` wires these hooks where supported:

- `handoff-inject.sh` - injects `HANDOFF.md` at the first Claude prompt in a
  4-hour window.
- `auto-handoff.sh` - snapshots git state to `HANDOFF.md` when Claude stops and
  the working tree has changes. Auto snapshots are FIFO-pruned to the last two.

Codex reads `AGENTS.md` natively. Pi uses `extensions/pi/handoff.ts`, installed
by `skills.sh init` when Pi is present.
