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

## Context Reset Handoff

A context reset clears the window entirely and starts a fresh agent. The regular
`HANDOFF.md` is for inter-session continuity (gaps between separate Claude
sessions). A reset handoff is for intra-session state transfer: it carries
exactly what the next agent needs to continue mid-sprint without re-reading
conversation history.

**When to write one:**
- Context window is approaching full and compaction has already been applied once
- A behavioral failure (context anxiety, premature wrap-up) makes continuing the
  current session unreliable
- You're at a defined phase boundary and want a clean slate for the next phase

**What it must carry:**

| Field | What to include |
|-------|----------------|
| Active sprint | Ticket ID, one-line goal, link to acceptance.md |
| Completed steps | Brief bullets — what's done and verified |
| Next steps | Concrete — exact file, function, or command |
| Open decisions | Any gray area not yet resolved that affects next steps |
| In-scope files | Files modified or staged; files the next step will need |
| Discoveries | Facts the next agent cannot derive from reading the code |

Omit anything the next agent can get from `ticket.md`, `plan.md`, or
`HANDOFF.md` — don't re-summarise what's already stable.

**Template:**

```markdown
# Context Reset Handoff — <ticket-id>

## Sprint
**Ticket:** `<id>` — <one-line goal>
**Acceptance:** `.tickets/<id>/acceptance.md`

## Completed
- <step> — verified by <grep / test / render>

## Next Steps
1. <exact action — file, line, or command>

## Open Decisions
- <question> — options: A / B; leaning A because <reason>

## In-Scope Files
- `<path>` — <current state>

## Discoveries
- <fact that won't survive without explicit transfer>
```

