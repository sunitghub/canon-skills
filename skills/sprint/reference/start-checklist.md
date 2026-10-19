---
name: start-checklist
description: One-page sprint-start checklist for a normal Claude Code sprint; points to start.md for high-risk and other cases
category: dev
tags: [workflow, planning, sprint]
hidden: true
---

# Sprint Start — checklist

The normal path. `start.md` holds each rule's full text and reasons: read only the section the last list
names for a case that applies.

## Steps

1. **Start:** `sprint start <ticket-id>` with the real id (a title only when no ticket exists). Then read the
   ticket's `ticket.md`, `acceptance.md`, `plan.md` and `research.md`. A template-only description is not
   "unspecified" when acceptance.md or plan.md hold the contract. Resuming an in_progress ticket:
   `sprint continue <id>`, then carry on from the first unchecked item.
2. **Skill check:** `tools/skills.sh list`; use a skill that covers the work.
3. **Tier:** normal or high-risk (`skills/sprint/SKILL.md` "Workflow tiers"). Never trivial or bugfix at
   start: those are close-time downgrades.
4. **Context:** `DECISIONS.md`: scan every live entry for a constraint or conflict, skipping fragments
   marked `superseded-by:`; `HANDOFF.md`; `LEARNINGS.md`; closed tickets that touched the files you will
   change.
5. **Research:** inspect the files and callers; write a few bullets in `research.md` before the approach.
6. **acceptance.md:**
   - `## Criteria`: binary conditions naming the exact field, value or output. Never cite `summary.md` or
     `eval-report.md`, which do not exist when the evaluator grades. A gitignored file
     (`DECISIONS.md`) is named as such, with "read it directly".
   - `## Test Plan`: a command or check per criterion. Each line names the prod path it protects (a shipped
     command, a board or daemon route a user hits, the release, or a close gate); a test with no prod path, or
     one that repeats another, is not added. Each path, variant or theme a line names is graded on its own.
     Evidence lives in `.tickets/<id>/evidence/`, written with
     `evidence.sh stamp <id> <name> -- <command>` on a clean tracked tree.
7. **plan.md:** `## Approach` (lean, re-read after every compaction), `## Files`, `## Decisions` (answer
   each ticket open question or write `carried forward: <question>`), and the tier with a one-line reason.
   If the project registered efficiency, name the `standards/efficiency-notes.md` sections this ticket
   touches and read only those. Name the number it moves and its target, or say why there is none.
8. **Perspective check:** one question each as user, security and architect; put any concern in the brief.
9. **Brief:** one-sentence goal; tier and reason; every applicable DECISIONS entry, conflicts called out;
   files; impact or "normal tier — no high-risk triggers found"; human checkpoint; criteria and Test Plan
   verbatim; each open question with its answer; blockers.
10. **Wait for explicit approval.** No code before it. Then fill `## Sign-off` (`Tier: <tier> | Risk: …`)
    and tick "Plan approved". A user's "run review/eval on <model>" goes in now as `| Gate model: <value>`.

## While building

- `plan.md` and `acceptance.md` are the source of truth; a scope change needs the user.
- Tick each box when its evidence exists, never in bulk.
- A changed or new criterion: update the Test Plan in the same pass (and `## Approach` if needed).

## Read the detail when

| Case | Read in `start.md` |
|---|---|
| high-risk sprint (security, irreversible, shared state, gray areas) | steps "Research high-risk work", "Grill high-risk work", "Impact analysis for high-risk work" |
| `type: bug` ticket or a refactor | step 4 "Job-type planning step"; step 5's bug-pattern note |
| docs, research or UX request (light close), or a `skills:` maintenance chore | step 3 "Docs/UX light-close recognition", "Maintenance-skills chore" |
| the change is user-visible (UI, CSS, theming) | step 4 "Visual acceptance criteria" |
| a new tool, endpoint or parser reads input it does not control | step 4 "Untrusted-input criterion" |
| Given/When/Then criteria | step 4 "Scenario-backed acceptance criteria" |
| a pasted image, mockup or design file | step 4 "Visual reference artifacts" |
| a full board spec or full-suite stamp | step 4 "Each item a `## Test Plan` line names" |
| a `tkt`/`sprint` command you do not know, or an unclear ticket field | step 1 (`tools/ticket.md`), step 4 (`standards/ticket-layout.md`) |
| a large file to understand, not edit | step 6 (`skills/bulk-read/SKILL.md`) |
| mid-sprint trivial downgrade | step 11 |
