---
name: promote-learnings
description: Reviews LEARNINGS.md's UNPROMOTED rows as a fresh, no-implementation-history reader and proposes where each durable one belongs — never writes to LEARNINGS.md, standards/, or critique/canon-learnings.md itself. Use as one of Upkeep's four report-only checks, or by hand when the UNPROMOTED queue needs triage.
category: agent-ops
tags: [learnings, sprint, memory, promotion]
---

# Promote Learnings

Read-only. Proposes, never promotes — the actual write into `critique/canon-learnings.md`,
`standards/`, or (rarely) `CLAUDE.md`/`AGENTS.md` stays a separate, later, human-confirmed act.
This skill exists because `learnings-sweep` (aggregation) and `tkt learn` (candidate generation)
explicitly refuse to make the promote/dismiss judgment call themselves — this is that judgment
call, made fresh, then handed back as a report, not an edit.

Distinct from `learnings-sweep`: that skill keeps `LEARNINGS.md`'s index current and never reads
a candidate's full detail. This skill reads each UNPROMOTED row's source
`.tickets/<id>/learnings.md` in full and judges whether it's durable enough to promote.

## Why this must run fresh, every time

The non-self-promote rule (`learnings-sweep`'s own SKILL.md) exists because the sprint that
produced a learning has no perspective on whether it generalizes — everything looks load-bearing
to the agent that just lived through it. This skill must run with no memory of the sprint(s) that
produced the candidates it's reviewing. When dispatched via Upkeep, this is automatic (every
dispatch is a fresh `claude -p` subprocess); if run by hand in an interactive session, start a
fresh session — do not run it in the same conversation that just closed the sprint(s) in question.

## Process

1. Read root `LEARNINGS.md`. For each row with `Status: UNPROMOTED`, read its linked
   `.tickets/<id>/learnings.md` in full (not just the one-line `Finding` cell — that's a terse
   distillation, the source file has the actual evaluator findings, reviewer findings and deviations).
2. For each row, judge: is this durable and general enough that a *different* future sprint would
   benefit from knowing it, or is it a one-off specific to that ticket's exact circumstances? A
   learning tied to one ticket's specific bug is not durable; a learning about a class of mistake
   (a testing anti-pattern, a doc-drift shape, a protocol gap) usually is.
3. For each durable row, propose exactly one destination:
   - **`standards/<file>.md`** — when the learning generalizes into a reusable rule (a checklist
     item, a naming convention, a "never do X, always do Y"). Propose the target file and a
     *starting-point example* of the rule text (not a final draft — a human still writes it).
   - **`critique/canon-learnings.md`** — when the learning is better told as a narrative (a
     concrete incident, why the naive fix failed, what worked instead) — that file's own voice is
     essay-style, not a bullet list (see its existing entries for the register to match). Propose
     a suggested outline/key points to hit, not full prose — authoring that narrative needs a
     human's judgment on tone and framing.
   - **`CLAUDE.md`/`AGENTS.md`** — rarely, only when the lesson must apply on *every* session
     regardless of what the session is doing (these are always-loaded, so cost is paid on every
     turn). Say explicitly why a narrower home (standards/ or a scoped reference) doesn't fit.
   - **The reference doc for the workflow step where the mistake happens** (e.g.
     `skills/sprint/reference/shared-gate-protocol.md` for gate mechanics, the skill's own
     `SKILL.md` gotchas for a single-skill quirk) — when the lesson only matters at one step.
     Propose the file and the section.

   **Choosing between them:** ask "at what moment would a future session make this mistake?" and
   pick the narrowest home that is read at that moment.
   - Applies to every session whatever it is doing → `CLAUDE.md`/`AGENTS.md`.
   - Applied while writing code, tests, commits or reviews → `standards/efficiency.md` (the only
     `standards/` file auto-loaded, via the `~/.claude/CLAUDE.md` import; another `standards/`
     file is read only on request, so a rule there needs a pointer from where it applies).
   - Only bites at one workflow step or in one skill → that step's reference doc or `SKILL.md`.
   - Needs its incident to be understood (why the obvious fix failed) → `critique/`.
   Before proposing, grep the destination for the same rule and extend it instead of adding a
   second copy. A row that spans two moments may be split into two proposals (as `t-6328` was).
   Keep any always-loaded rule to one or two lines; its cost is paid every session.
4. For each non-durable row, recommend dismissal with a one-line reason.
5. Never edit `LEARNINGS.md`, any file under `standards/`, `critique/canon-learnings.md`,
   `CLAUDE.md`, or `AGENTS.md` — this skill's own report is the only output.

## Report format

```markdown
# Promote Learnings Report

## Reviewed
<N> UNPROMOTED rows read in full from their source .tickets/<id>/learnings.md files.

## Proposals

### <ticket-id>: <one-line summary of the learning>
- **Durable:** yes/no — <why>
- **Proposed destination:** standards/<file>.md | critique/canon-learnings.md | CLAUDE.md/AGENTS.md | <workflow reference doc>#<section> | dismiss
- **Starting point:** <example rule text, or outline/key points, or the dismissal reason>

<repeat per row>

## Next Steps

> This skill never writes these changes itself. Apply them by hand: edit the destination
> file below, bump that file's frontmatter `version` and set `updated` to today (if it has
> them), then flip each promoted row's Status in LEARNINGS.md away from UNPROMOTED. Record the
> target in the cell — `` `promoted → standards/efficiency.md` `` (whole value in backticks so
> editors highlight it; or `dismissed`) — so where a lesson went is readable from the row without
> git archaeology.

<Include the frontmatter bump ("bump `version` 1.0.5 → 1.0.6, `updated` → <today>") in each
destination's action. Concrete, per-proposal actions a human can take — e.g. "Add the following to
standards/efficiency.md: ..." or "Consider writing a critique/canon-learnings.md section
covering: ...". Never performed by this skill itself.>
```

## Gotchas

- A row this skill proposes for promotion is not confirmed — a human (or a later, separate,
  non-builder pass) still decides and writes it. Do not mark a row `PROMOTED` anywhere; that
  field only changes when the actual write happens, outside this skill.
- If `LEARNINGS.md` has zero UNPROMOTED rows, say so plainly in the report — an empty queue is a
  valid, unremarkable result, not an error.
- When recording or backfilling a `promoted → <file>` target, the lesson itself must appear in a real
  content line of that file. Read each grep hit: a ticket-ID match in a template or example row (e.g.
  the sample row in `skills/learnings-sweep/SKILL.md`) is not evidence. With no real hit, leave the
  row plain `promoted` rather than guessing.
