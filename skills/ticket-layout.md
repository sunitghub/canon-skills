---
name: ticket-layout
description: Canonical ticket structure contract — folder layout, frontmatter fields, sprint doc lifecycle, board rendering, and migration rules
category: dev
tags: [tickets, schema, contract, internal]
hidden: true
---

# Ticket Layout

Internal reference. Defines the canonical structure for all canon tickets. Update this skill whenever ticket layout, frontmatter fields, doc lifecycle, or board rendering rules change.

---

## Folder Structure

```
.tickets/
  ACTIVE                    ← plain text: ID of the in-progress ticket
  <id>/
    ticket.md               ← frontmatter + body (tkt-managed)
    acceptance.md           ← sprint doc (agent-created)
    plan.md                 ← sprint doc (agent-created)
    research.md             ← sprint doc (optional; agent-created for high-risk)
    summary.md              ← sprint doc (agent-created at close)
```

The `.tickets/<id>/` layout is **canonical** (folder layout). The legacy flat layout (`.tickets/<id>.md`) is read by the board and server for backwards compatibility but never written by new tooling.

---

## Frontmatter Contract

Every `ticket.md` begins with a YAML-style frontmatter block followed by a markdown body:

```
---
id: t-xxxx
status: open
created: 2026-06-13T10:00:00Z
type: task
priority: 2
title: Short description
---

## Body heading
...
```

### Fields

| Field | Type | Authority | Notes |
|---|---|---|---|
| `id` | string | `tkt` | Format: `t-[a-z0-9]{4}`. Immutable after creation. |
| `status` | enum | `tkt` | See allowed values below. |
| `created` | ISO 8601 | `tkt` | Set once at creation. |
| `type` | enum | `tkt` | See allowed values below. |
| `priority` | int 0–4 | `tkt` | 0 = highest. Default: 2. |
| `title` | string | `tkt` / agent | Derived from markdown heading or explicit field. |

### Allowed Values

**status:** `open` · `in_progress` · `closed` · `cancelled`

Board labels: Open → In Progress → Done → Discarded (`cancelled` is the status value for "Discarded").

**type:** `bug` · `feature` · `task` · `epic` · `chore`

**priority:** `0` (critical) · `1` (high) · `2` (normal) · `3` (low) · `4` (someday)

---

## Sprint Doc Lifecycle

Sprint docs are created by the agent inside `.tickets/<id>/`. They are not managed by `tkt`.

| Doc | Created when | Required for close | Content |
|---|---|---|---|
| `acceptance.md` | `sprint start` | yes — `## Criteria` and `## Test Plan` each need ≥1 checklist item; `## Wrapup Gates` must exist | Definition of done, test plan, wrapup gate record |
| `plan.md` | `sprint start` | yes — `## Approach` must have non-placeholder content | Approach, files, decisions; read after compaction |
| `research.md` | High-risk / brownfield orient | no — optional | Objective truth compression: relevant files, system model, constraints, unknowns |
| `summary.md` | `sprint complete` step 8 | yes — must exist before close | Plan-vs-actual table; one row per acceptance criterion |

**Doc-less tickets** — tickets with no sprint docs are valid (e.g. backlog items, tasks that don't need a sprint). The board renders the ticket body in the modal instead of doc tabs.

---

## Board Rendering Rules

The board (`sprint-check-app`) derives all rendering from the ticket JSON produced by `server.py`.

| Ticket state | Board column | Doc tabs | Readiness indicator |
|---|---|---|---|
| `open` | Open | any docs present | red dot if `acceptance_has_items` is false or `plan_has_approach` is false |
| `in_progress` | In Progress | any docs present | same as open |
| `closed` | Done | all docs shown read-only | no readiness indicator |
| `cancelled` | Discarded | all docs shown read-only | de-emphasized (55% opacity) |

**Server-side computed fields** (injected into ticket JSON):
- `layout`: `'folder'` or `'flat'`
- `acceptance_has_items`: `true` if `## Criteria` and `## Test Plan` each have ≥1 real checkbox item; `false` if missing or empty; `null` if no `acceptance.md`
- `plan_has_approach`: `true` if `## Approach` has non-placeholder content; `false` if empty/template-only; `null` if no `plan.md`
- `docs`: array of `{ name, file }` for each companion `.md` in the ticket folder (excluding `ticket.md`)

**Hidden docs** — `ticket.md` is excluded from the docs tab list. The board never renders it as a tab.

---

## Read/Write Rules

- `tkt` owns `ticket.md` — fields are written only via `tkt create`, `tkt start`, `tkt close`, `tkt reopen`. Agents must not edit `ticket.md` frontmatter directly.
- Sprint docs are agent-owned — the agent creates and edits `acceptance.md`, `plan.md`, `research.md`, `summary.md`.
- Closed tickets — `sprint complete` runs `tkt close`, which sets `status: closed` and removes `ACTIVE`. Sprint docs become read-only on the board. The agent must not reopen a ticket after close without explicit user instruction.
- ACTIVE file — `.tickets/ACTIVE` contains exactly one ticket ID when a sprint is in progress. `tkt start` writes it; `tkt close` removes it. Only one sprint may be active at a time.

---

## Migration Rules

### Flat → Folder

Legacy flat tickets (`.tickets/<id>.md`) are read by the server and board but are not written by any current tooling. They have no companion sprint docs.

To migrate a flat ticket to folder layout:
1. Create `.tickets/<id>/` directory
2. Move `.tickets/<id>.md` to `.tickets/<id>/ticket.md`
3. Move any companion docs (`.tickets/<id>-acceptance.md` → `.tickets/<id>/acceptance.md`, etc.)

No automated migration tooling exists. Migration is manual and optional — flat tickets display correctly on the board.

### Future Schema Changes

When adding new frontmatter fields or changing allowed values:
1. Update this skill first.
2. Update `tools/tkt` (creation and display).
3. Update `tools/sprint-check-app/server.py` (parsing and computed fields).
4. Update `tools/sprint-check-app/app.html` (rendering).
5. Add or update tests.

---

## Test Expectations

When ticket layout or board rendering changes, tests must cover:

- `tests/tkt.sh` — frontmatter field creation, status transitions, ACTIVE file management
- `tests/sprint.sh` — sprint doc scaffolding at `sprint start`; gate behavior at `sprint complete`
- `tests/sprint-check-server.sh` — server parses folder and flat layout; computed fields are correct
- `tests/sprint-check-app.spec.js` (Playwright) — board renders doc tabs; readiness indicators; modal body for doc-less tickets

Any change to `DOC_TYPES` in `app.html`, doc scaffolding in `tools/sprint`, or server parsing in `server.py` requires both the bash suite and Playwright suite to pass before merge.
