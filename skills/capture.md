---
name: capture
description: Proactively record non-obvious discoveries to HANDOFF.md and memory — fires automatically mid-session, also invocable explicitly
category: dev
tags: [knowledge-management, handoff, memory]
---

# Capture — Knowledge Preservation

## Automatic behavior

When you find something non-obvious that would need re-investigation if lost:

1. Append it to `HANDOFF.md` under `## Discoveries` (create the section after `## Recent Decisions` if it doesn't exist)
2. Save a `project` memory to the project memory store

**What qualifies:**
- Filter or exclusion rules found by comparing data sets or running experiments
- Numerical facts not derivable from code (record counts, row limits, offsets)
- Environment gotchas — args, paths, config file locations, tool behavior differences, build quirks
- Architecture decisions with non-obvious WHY (especially when alternatives were ruled out)
- Any constraint or rule that required active investigation to establish and isn't visible in the code

**What doesn't qualify:**
- Things obvious from reading the code
- Standard framework or library behavior
- Decisions that are trivial and will be captured by the next wrapup

## Explicit invocation

1. Append to `HANDOFF.md` under `## Discoveries`. Create the section if absent.
2. Save a `project` memory.
3. Confirm in one line: "Captured: <summary>"

Entry format for HANDOFF.md:
```
- **[YYYY-MM-DD]** <what was discovered> — <why it matters or how to apply it>
```

**Trigger syntax:**

| Agent | How to trigger |
|---|---|
| Claude Code | `/capture <text>` |
| Codex / Pi | "Capture this" / "Record this in discoveries" / "Add this to HANDOFF" |
