---
name: handoff
description: Session context handoff protocol — keeps Claude and Codex in sync across repos and agents
category: tools
tags: [context, memory, handoff, multi-agent]
---

# Handoff — Session Context Protocol

This project uses a `HANDOFF.md` file in the repo root to preserve working context across sessions and agents. It bridges the gap between Claude, Codex, and any other agent that touches this repo.

## Getting Started

**Step 1 — Register this skill in your project:**
```bash
~/Developer/AI-Skills/skills.sh add handoff /path/to/your/project
```

**Step 2 — Verify:**
```bash
~/Developer/AI-Skills/skills.sh status /path/to/your/project
```

**Step 3 — Create `HANDOFF.md` in the repo root** (first time only):

Tell the agent: "Initialize the handoff file" — it will create it from the template below. Or create it manually using the format in this file.

**Step 4 — Use it:**
- **At session start**: The agent reads `HANDOFF.md` automatically and tells you where things stand before doing anything.
- **During a session**: The agent updates it when significant decisions are made or direction changes.
- **At session end**: Tell the agent "wrap up" or "handoff" — it updates `HANDOFF.md` and commits it.
- **Switching agents**: The next agent (Claude or Codex) reads the committed `HANDOFF.md` and picks up in context.

## The problem it solves

AI agents don't share memory. When you switch from Codex to Claude (or vice versa), the new agent starts cold. `HANDOFF.md` is the shared state — a lightweight, git-tracked snapshot of where things stand.

## Agent Responsibilities

### On session start
1. Check if `HANDOFF.md` exists in the repo root.
2. If it exists, read it before doing anything else.
3. Acknowledge the current state to the user before proceeding.

### During a session
- Update `HANDOFF.md` when significant decisions are made.
- Update it when a direction changes or a dead end is hit.

### On session end (or when user says "handoff", "wrap up", "done for now")
1. Update `HANDOFF.md` with current state.
2. Commit it: `git add HANDOFF.md && git commit -m "Update handoff state"`
3. Confirm to the user it's been committed.

## HANDOFF.md Format

```markdown
# Handoff

_Last updated: <date> by <agent> (<model>)_

## Current Focus
<!-- One sentence: what are we working on right now -->

## In Progress
<!-- What's started but not finished — include file paths and ticket IDs if relevant -->
- 

## Recent Decisions
<!-- Key choices made and WHY — not what, why. Omit obvious things. -->
- 

## Dead Ends
<!-- What was tried and didn't work, so the next agent doesn't repeat it -->
- 

## Open Questions
<!-- Unresolved things that need a decision before proceeding -->
- 

## Next Steps
<!-- Concrete next actions, in priority order -->
1. 
```

## Creating HANDOFF.md in a new repo

If `HANDOFF.md` doesn't exist, create it from the template above and populate **Current Focus** and **Next Steps** before committing.

```bash
# Quick start
cat > HANDOFF.md << 'EOF'
# Handoff

_Last updated: $(date +%Y-%m-%d) by <agent>_

## Current Focus


## In Progress
-

## Recent Decisions
-

## Dead Ends
-

## Open Questions
-

## Next Steps
1.
EOF
```

## Rules

- Keep it short. This is a handoff note, not a journal.
- **Current Focus** is one sentence max.
- **Recent Decisions** captures the WHY — the diff already shows the what.
- Prune stale entries. Dead ends and decisions older than the current feature branch can be removed.
- Always commit `HANDOFF.md` before ending a session. An uncommitted handoff is useless.
- Do not put secrets, credentials, or environment-specific values in this file.
