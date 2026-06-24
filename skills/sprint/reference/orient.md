---
name: orient
description: Map the sprint target subsystem before editing
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

## Step 3 — Flag non-obvious relationships

Flag likely affected files missing from the plan. Note generated files, monorepo layout, or other navigation gotchas.

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
| `path/file.ext:42 — \`quoted text\`` | Entry point for X | Function Y calls Z |

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

## Parallel Research

Use when `plan.md` identifies **2 or more independent subsystems** — subsystems whose exploration results don't depend on each other (e.g. auth layer, API endpoints, and job queue can be traced simultaneously; a model and its migration cannot).

**Trigger:** count the distinct subsystems in `plan.md ## Files`. If ≥ 2 have no shared entry points, use parallel research.

**How to run:**

Spawn one Explore subagent per subsystem in a single message (parallel). Each subagent receives:
- The subsystem name
- Its known entry point(s) from `plan.md`
- Instruction: survey entry points, trace imports and callers, flag non-obvious relationships, list every relevant file with a `file:line — \`quoted text\`` citation. Read only.

Each subagent writes its findings to `.tickets/<id>/research-<subsystem>.md`.

**Valid completion — content, not existence:**

A partial file is valid only if it contains at least one `file:line — \`quoted text\`` citation under `## Relevant Files`, OR a sentinel line in this exact form:

```
no relevant files found for <subsystem> — searched: <comma-separated paths or globs examined>
```

Example: `no relevant files found for job-queue — searched: jobs/, workers/, lib/queue*, tests/jobs*`

File existence alone is not a completion signal — a subagent can create an empty or stub file without doing any work. A bare sentinel without the `searched:` clause is treated as invalid (same as missing). The paths listed must reflect actual search locations; this is what distinguishes "looked and found nothing" from "never looked".

**After all subagents complete:**

1. Read each `.tickets/<id>/research-<subsystem>.md`.
2. For each partial file that is missing or invalid (exists but has no `file:line` and no sentinel): add an entry to `research.md ## Unknowns` — `"<subsystem>: subagent did not produce valid output"`.
3. Synthesize valid partials into a single `research.md` following the Step 4 structure.
4. Delete the per-subsystem partial files.

**Failure modes:**

| Condition | Action |
|---|---|
| Partial file missing (timeout / error) | Log in `## Unknowns`; proceed with remaining subsystems |
| Partial file invalid (no `file:line — \`quoted text\``, no sentinel) | Treat same as missing |
| Sentinel present with `searched:` clause | Accept as valid; note in `## System Model` |
| Sentinel present but missing `searched:` clause | Treat as invalid — same as missing |
| All partials missing or invalid | Fall back to single-threaded Steps 1–4; note fallback in `## Unknowns` |
| Some valid, some not | Synthesize valid; surface gaps at the research review checkpoint |

Gaps in `## Unknowns` surface naturally at the `sprint start` research review checkpoint — no new gate needed.

## Scope rules

- Read only. No edits.
- Stay in the relevant subsystem.
- Fill gaps; do not repeat the user's explanation.
- Research is compression of truth. Do not decide how to implement here.
  Record only what the system does, which files matter, what constraints exist,
  and what remains unknown. Opinions and approach belong in the Plan step.
- Every important claim must reference a file path or line number with the quoted line text — `file:line — \`quoted text\``. A line number without the quoted content is unfalsifiable.
- List excluded near-miss files and why they were ruled out — this prevents
  future re-reading of the same candidates.
- Subagent transcripts are disposable. The only durable output is `research.md`.
