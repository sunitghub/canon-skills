---
name: orient
description: Read-only subsystem exploration — maps the codebase around the sprint's target files and writes findings to blueprint.md before any editing begins
summary: Surveys file structure, entry points, and cross-file dependencies for the sprint's target area. Writes a Subsystem Map to blueprint.md. Called automatically by sprint start — not a separate invocation.
category: dev
tags: [planning, exploration, context, codebase]
hidden: true
---

# Orient

Read-only exploration of the subsystem relevant to the current sprint. Runs before any edits — its job is to map, not modify.

Called automatically by `sprint start` after context documents are read. Do not invoke directly.

---

## When to run

Automatically during `sprint start` — not a separate invocation. Runs after DECISIONS.md and HANDOFF.md are read, before the Grill step, so findings are available when surfacing gray areas.

---

## Step 1 — Survey the target area

Read the directory structure and files around the planned changes. Focus on:
- Entry points: where does execution flow into these files?
- Interfaces: what do these files export or expose?
- Adjacent modules: what sits alongside the target files in the same directory?

Limit scope to the relevant subsystem — not the whole repo. If DECISIONS.md contains constraints that affect how to read the subsystem, honor them here.

---

## Step 2 — Trace dependencies

For each file marked for modification in `blueprint.md`:
- What does it import?
- What imports it? (grep for the filename or exported symbols)
- Any shared types, constants, or schemas it exposes?

---

## Step 3 — Flag non-obvious relationships

Identify files not in the original plan that are likely affected by the sprint's changes — candidates for the blueprint.md file list. Note them explicitly.

If the codebase has an unconventional structure (generated files mixed with source, monorepo with non-standard layouts, binary assets), note it so sprint can account for it.

---

## Step 4 — Write findings

Append a `## Subsystem Map` section to `blueprint.md`:

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

If the subsystem is simple and the original blueprint already covers it fully, write a one-line confirmation instead:

```markdown
## Subsystem Map — confirmed: original file list is complete, no non-obvious relationships found
```

---

## Scope rules

- Read only. No edits during orient.
- Stay in the relevant subsystem. Do not explore unrelated areas of the repo.
- Orient fills gaps — do not re-describe what the user already explained clearly.
