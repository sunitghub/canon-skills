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

Append a `## Subsystem Map` section to `plan.md`:

```markdown
## Subsystem Map

### Entry points
- `file:line` — one-line description of how execution reaches the target area

### Key interfaces
- `file` — what it exports and who depends on it

### Adjacent modules
- `file` — one-line description (include only if relevant to the sprint)

### Non-obvious relationships
- `file` — why it may be affected despite not being in the original plan

### Structural notes
- Any non-obvious conventions, generated files, or layout quirks that affect navigation or editing

### Open questions
- Ambiguities about the subsystem that could affect implementation (or "None")
```

If plan.md already covers the subsystem, write:

```markdown
## Subsystem Map — confirmed: original file list is complete, no non-obvious relationships found
```

---

## Scope rules

- Read only. No edits.
- Stay in the relevant subsystem.
- Fill gaps; do not repeat the user's explanation.
