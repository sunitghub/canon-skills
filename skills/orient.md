---
name: orient
description: Map the sprint target subsystem before editing
summary: Read entry points, interfaces, adjacent modules, and dependencies. Write a Subsystem Map to plan.md. Called by sprint start.
category: dev
tags: [planning, exploration, context, codebase]
hidden: true
---

# Orient

Called by `sprint start` after context documents are read.

## Step 1 — Survey the target area

Read the target area. Focus on:
- Entry points: where does execution flow into these files?
- Interfaces: what do these files export or expose?
- Adjacent modules: what sits alongside the target files?

Limit scope to the relevant subsystem.

## Step 2 — Trace dependencies

For each file marked for modification in `plan.md`:
- What does it import?
- What imports it? (grep for the filename or exported symbols)
- Any shared types, constants, or schemas it exposes?

---

## Step 3 — Flag non-obvious relationships

Flag likely affected files missing from the plan. Note generated files, monorepo layout, or other navigation gotchas.

---

## Step 4 — Write findings

Write findings to `.tickets/<id>/research.md`. If it does not exist, create it
with the structure below. If it already exists, update the relevant sections.

```markdown
# Research

Ticket: `<id>`

## Objective
One sentence: what system behavior was researched.

## Relevant Files
| File | Why relevant | Evidence |
|---|---|---|
| `path/file.ext:42` | Entry point for X | Function Y calls Z |

## System Model
- Fact about how the subsystem works.
- Fact about data flow or control flow.

## Constraints
- Non-obvious constraint and its source.

## Unknowns
- Question that must be resolved before planning, or "None".

## Not In Scope
- Relevant-looking files intentionally excluded and why.
```

If the subsystem is already fully described in `plan.md` and no new files or
relationships were discovered, note this in `research.md ## System Model` and
keep the entry brief.

---

## Scope rules

- Read only. No edits.
- Stay in the relevant subsystem.
- Fill gaps; do not repeat the user's explanation.
- Research is compression of truth. Do not decide how to implement here.
  Record only what the system does, which files matter, what constraints exist,
  and what remains unknown. Opinions and approach belong in the Plan step.
- Every important claim must reference a file path or line number.
- List excluded near-miss files and why they were ruled out — this prevents
  future re-reading of the same candidates.
- If the agent supports subagents, delegate file location and dependency tracing
  to subagents. The only durable output is the Subsystem Map in `plan.md`;
  subagent transcripts are disposable.
