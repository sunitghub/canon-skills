---
name: capture
description: Record non-obvious discoveries to HANDOFF.md and project memory
category: dev
tags: [knowledge-management, handoff, memory]
---

# Capture

## When to Capture

- Filter or exclusion rules found by comparing data sets or running experiments
- Numerical facts not derivable from code (record counts, row limits, offsets)
- Environment gotchas: args, paths, config locations, tool behavior, build quirks
- Architecture choices with non-obvious reasons
- Constraints discovered through investigation and not visible in code

## Do Not Capture

- Things obvious from reading the code
- Standard framework or library behavior
- Decisions that are trivial and will be captured by the next wrapup

## Action

1. Append to `HANDOFF.md` under `## Discoveries`. Create the section if absent.
2. Save a `project` memory.
3. Reply: `Captured: <summary>`

Entry format for HANDOFF.md:
```
- **[YYYY-MM-DD]** <what was discovered> — <why it matters or how to apply it>
```

## Triggers

| Agent | How to trigger |
|---|---|
| Claude Code | `/capture <text>` |
| Codex / Pi | "Capture this" / "Record this in discoveries" / "Add this to HANDOFF" |
