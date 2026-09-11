---
name: learnings-sweep
description: Aggregates per-ticket UNPROMOTED .tickets/<id>/learnings.md candidates into a single capped root LEARNINGS.md index, without promoting any of them. Use after `tkt learn <id>` confirms a candidate (single-ticket mode, called from sprint complete), or run `--full` by hand to backfill/reconcile the whole repo.
category: agent-ops
tags: [learnings, sprint, memory, aggregation]
---

# Learnings Sweep

Aggregation only — never promotion. Distinct from `tkt learn` (writes one ticket's candidate) and
from moving a keeper into `critique/canon-learnings.md`, `standards/`, or `CLAUDE.md`/`AGENTS.md`
(a non-builder's separate, later act — see Promotion destinations below). This skill only keeps
root `LEARNINGS.md` a current, compact index of what `tkt learn` has produced across tickets — it
never changes a row's `Status` away from `UNPROMOTED`.

## Promotion destinations (not this skill's job — context for what "promote" means)

A non-builder promoting a keeper from `LEARNINGS.md` chooses among three places, in order of
preference:

1. **`critique/canon-learnings.md`** — narrative critique log, the default for most keepers.
2. **`standards/`** — a formal, reusable standard the keeper generalizes into.
3. **`CLAUDE.md`/`AGENTS.md`** — rarely. These are always-loaded into every session's context, so
   every line costs tokens on every turn regardless of relevance (the same progressive-disclosure
   concern `context-doctor`'s lens 3 checks for). Reserve this destination for a lesson that must
   apply on every session, not just the ones that happen to touch the relevant area — anything
   narrower belongs in `standards/` or a scoped reference file instead.

This skill never makes that choice — it only keeps the candidate queue current so a non-builder has
something to choose from.

## When to use

- **Single-ticket** (`learnings-sweep <id>`) — called from `skills/sprint/reference/complete.md`
  step 8, right after `tkt learn <id>` confirms/writes `.tickets/<id>/learnings.md`. Also runnable
  by hand to re-sync one ticket's row after manually editing its `learnings.md`.
- **`--full`** (`learnings-sweep --full`) — manual only, never auto-called. Backfills
  `LEARNINGS.md` from scratch, or reconciles drift (a `learnings.md` created outside `sprint
  complete`, or the root file hand-edited).

## Single-ticket mode

Input: a ticket id (`t-xxxx`). No glob.

1. Read `.tickets/<id>/learnings.md`. If absent, stop — nothing to sweep (report this, don't error).
2. Extract: `generated` date (frontmatter), the ticket title (H1, after `Learnings candidate —
   <id>: `), a one-line finding (compress `## Evaluator findings`/`## Deviations` down to the single
   most load-bearing sentence — prefer a `Candidate lessons` checklist item if any are filled in,
   else the first substantive evaluator finding), and `status` (frontmatter — almost always
   `UNPROMOTED` at this point).
3. Upsert into `LEARNINGS.md`'s table: if a row for this ticket id already exists, replace it in
   place (don't duplicate, don't reorder past its original position unless the date changed). If
   new, insert at the top (newest first).
4. Rewrite the top-of-file stamp (see Format below).
5. Apply the cap (see Overflow below).

## `--full` mode

1. Glob `.tickets/*/learnings.md`.
2. Parse `LEARNINGS.md`'s existing table for ticket ids already present.
3. For each globbed file whose ticket id is missing from the table, or whose `learnings.md` mtime
   is newer than the row's recorded date, run the single-ticket extraction (step 2 above) and
   upsert.
4. Rows in the table with no corresponding `.tickets/<id>/learnings.md` on disk (the source was
   deleted) are removed — the row's only reason to exist is as a pointer to that file.
5. Rewrite the stamp, apply the cap.

## Format

`LEARNINGS.md` at the repo root:

```markdown
# Learnings

learnings-sweep last run: MM-DD-YYYY hh:mm

<!-- canon:learnings:BEGIN -->
| Date | Ticket | Finding | Status |
|---|---|---|---|
| 2026-08-24 | [t-96a8](.tickets/t-96a8/learnings.md) | <one-line finding> | UNPROMOTED |
<!-- canon:learnings:END -->
```

- Newest row on top by `Date`.
- `Ticket` links to the source `.tickets/<id>/learnings.md` — the table is an index, not a copy;
  full detail always lives in the source file.
- The stamp line sits **above** the markers and is rewritten on every run, single-ticket or full —
  it is not part of the size cap.
- Per `standards/skill-setup-std.md`'s canon-managed-content convention: only the lines between
  `<!-- canon:learnings:BEGIN -->` and `<!-- canon:learnings:END -->` count toward the cap or are
  ever mechanically touched. Leave a blank line on either side of the markers.

## Cap and overflow

The managed block (table header + rows, between the markers) is capped at **80 lines** — matching
`HANDOFF.md`'s existing convention.

When an upsert would push the block over the cap:

1. Look for the oldest rows whose `Status` is **not** `UNPROMOTED` (i.e. already `promoted` or
   `dismissed` by a prior non-builder pass). Move those — oldest first — to `LEARNINGS-archive.md`
   (create it if absent, same append-only table format, no cap) until back under the cap.
2. If every row is still `UNPROMOTED` and the cap is still exceeded, **do not archive anything**. A
   pending, unreviewed row must stay visible. Instead print an advisory: `LEARNINGS.md is over the
   80-line cap and every row is still UNPROMOTED — a promotion/triage pass is due.` Never block —
   this mirrors `learnings.md` itself being "never close-gated."

## Gotchas

- Never write to `critique/canon-learnings.md` or any file under `standards/` — that is promotion,
  a distinct, later, non-builder act. This skill's own edits must never change a `Status` cell away
  from `UNPROMOTED`.
- Single-ticket mode must not glob `.tickets/*` — that defeats the reason `sprint complete` calls it
  on every close (O(1) per ticket, not O(n) per close). If you find yourself scanning all tickets in
  single-ticket mode, that's `--full`'s job, not this path's.
- A ticket's `learnings.md` can be deleted or regenerated (`tkt learn <id> --force`) at any time —
  `--full` mode is the reconciliation path for exactly that drift; single-ticket mode assumes the
  file it's pointed at is current.
