---
name: ticket-layout
description: Canonical ticket structure contract — folder layout, frontmatter fields, sprint doc lifecycle, board rendering, and migration rules
category: dev
tags: [tickets, schema, contract, internal]
hidden: true
version: 1.3.0
updated: 2026-07-26
---

# Ticket Layout

Internal reference. Defines the canonical structure for all canon tickets. Update this skill whenever ticket layout, frontmatter fields, doc lifecycle, or board rendering rules change.

## Folder Structure

```
.tickets/
  ACTIVE                    ← plain text: ID of the in-progress ticket
  <id>/
    ticket.md               ← frontmatter + body (tkt-managed)
    acceptance.md           ← sprint doc (agent-created)
    plan.md                 ← sprint doc (agent-created)
    research.md             ← sprint doc (agent-created; brief for normal-tier, full orient protocol for high-risk)
    review-notes.md         ← sprint doc (agent-created at close, normal+; advisory reviewer findings)
    eval-report.md          ← sprint doc (agent-created at close, normal+; adversarial criterion grades)
    mutation-report.md      ← optional advisory (mutation-test skill at close, normal+ when logic files changed; never close-gated)
    learnings.md            ← optional UNPROMOTED lessons candidate (`tkt learn` at/after close; deviations + evaluator findings, for a non-builder to promote; never close-gated)
    summary.md              ← sprint doc (agent-created at close)
```

The `.tickets/<id>/` layout is **canonical** (folder layout). The legacy flat layout (`.tickets/<id>.md`) is read by the board and server for backwards compatibility but never written by new tooling.

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
| `ci` | bool | `tkt` | Optional. `true` marks the ticket CI-eligible for headless grading (`tkt ci <id> on`/`off`). Absent by default — most tickets are never CI-eligible. Setting it does not touch git; the ticket's `.tickets/<id>/` docs must still be force-added once (`git add -f`) since `.tickets/` is gitignored by default — `tkt ci` prints this reminder. |
| `gate` | enum | `tkt` / board | Optional headless-gate mode, meaningful only when `ci: true`. `gate: eval` = the board's ▶ run button (and a generated CI workflow) dispatches `sprint-headless-eval` (evaluator only) against the ticket; **absent = `full`** (the default `sprint-headless` reviewer + evaluator + security-review pipeline). Present/absent mirrors `ci`. Set via `tkt gate <id> eval|full` (`full` removes the line) or the New Ticket form's **Eval-only** toggle. Board-side dispatch reads this committed value so the run button and any generated workflow agree on one source of truth. |
| `demo` | bool | `tkt` | Optional. `true` puts `sprint complete` on the **demo close-path** (one light-close for two user-elected intents — a live demo, or a docs/research/UX-mockup sprint whose whole surface is `.md`/`.pen` + visuals; surfaced as the New-Ticket **Demo/Docs/UX** option): keep only `security-review` + the binding evaluator (the **evaluator** forced to Haiku unless an explicit `Gate model:` is set; `security-review` runs inline on the session model), skip the advisory reviewer + the rest of wrapup, with loud `skipped \| demo mode` Wrapup Gates rows and a `summary.md` demo line. Absent by default. It **never drops below the binding evaluator** (so it never involves `eval_override`) and changes no CLI gate — the reduction is a user-flag exception to the "only structural risk reduces gates" invariant (see `AGENTS.md`'s north-star exception + `DECISIONS.md` 2026-07-30 / 2026-08-02). Headless/CI ignores `demo`. Set via the shipped `tkt demo <id> on` command or hand-set in frontmatter; board surfaces are Phase A. |
| `eval_override` | bool | `tkt` seeds `false`; **human only** sets `true` | `tkt create` (and thus `sprint start`) seeds every new ticket with `eval_override: false`, so the field is discoverable. `true` lets `sprint complete`'s `_gate_eval_report` close a ticket despite a `fail:` evaluator verdict — but the CLI check is deliberately coarse: it only confirms the flag is `true` and that `acceptance.md` records at least one dated waiver. Per-item "is this specific failing item genuinely waived" is verified by a human at `complete.md`'s steps 4-5 close-gate, not re-derived mechanically — a mechanical per-item check (text-matching, then position-based correlation) was built and abandoned as fundamentally unsound across five rounds of adversarial review; see `DECISIONS.md` (`t-c0e6`). **No `tkt` command ever sets this field to `true` — the only write path for `true` is a human hand-editing `ticket.md`'s frontmatter directly** (`t-7cd5`). Agents must never write, set, or toggle this field to `true` under any circumstance, including explicit user instruction — if asked, refuse and tell the user to hand-edit `ticket.md` themselves. A CLI setter is only behaviorally human-gated (an agent could still invoke it on request), not mechanically — removing the write-to-`true` path removes the agent's ability to self-approve a close-gate override entirely. |
| `eval_fail_count` | int | `tkt` seeds `0`; `sprint eval-verdict <id>` increments/resets | `tkt create` seeds every new ticket with `eval_fail_count: 0`. `complete.md` step 3 runs `sprint eval-verdict <id>` immediately after reading each evaluator dispatch's verdict from `eval-report.md`: increments the field by 1 on `fail`, resets to `0` on `pass`. Before the next evaluator dispatch, the agent reads this field and, if it has reached 3, skips dispatch and tells the human the retry budget is exhausted instead of auto-redispatching. This is a soft, informational nudge only — it does not change `_gate_eval_report_verdict`'s close-gate mechanics or add a second enforcement layer on top of `eval_override`, which remains the sole close-time override. Falls back to appending the field if a pre-existing ticket lacks it (`_set_field_or_append` in `tools/sprint`), so tickets created before this field existed are unaffected (`t-16a8`). |
| `closed` | ISO 8601 | `tkt` | Optional CLI close marker. `cmd_set_status` writes `closed: <UTC timestamp>` whenever a ticket transitions to `status: closed` (via `sprint complete` or `tkt close [--no-sprint]`) and removes it on any other transition (reopen/start/archive). The git-native pre-commit hook keys off a **co-added** `closed:` line in a `ticket.md` diff to tell a legitimate CLI close from a hand-edited `status: closed`, so a previously-committed (e.g. interim-committed `in_progress`) ticket can be closed via the CLI without a false-positive block; a bare hand-edit that flips only `status` has no marker and is still blocked (`t-dec8`). Not forgery-proof by design (per `t-c0e6`/`t-d8a1` — no gate is bypass-proof; the honest path is easy, the dishonest path loud). Inert where `.tickets/` is gitignored (never committed, never read by the hook). |

### Allowed Values

**status:** `open` · `in_progress` · `closed` · `cancelled`

Board labels: Open → In Progress → Done → Discarded (`cancelled` is the status value for "Discarded").

**type:** `bug` · `feature` · `task` · `epic` · `chore`

**priority:** `0` (critical) · `1` (high) · `2` (normal) · `3` (low) · `4` (someday)

## Sprint Doc Lifecycle

Sprint docs are created by the agent inside `.tickets/<id>/`. They are not managed by `tkt`.

| Doc | Created when | Required for close | Content |
|---|---|---|---|
| `acceptance.md` | `sprint start` | yes — `## Criteria` and `## Test Plan` each need ≥1 checklist item; `## Wrapup Gates` must exist; **and no box may be left unchecked** — any unchecked `- [ ]` anywhere in the file (including `## QA`'s "Tested locally") blocks close (`tools/sprint` `_gate_no_unchecked`) | Definition of done, test plan, wrapup gate record |
| `plan.md` | `sprint start` | yes — `## Approach` must have non-placeholder content; `## Sign-off` must exist with no unchecked items and at least one checked approval (skipped only if `Tier: trivial`) | Approach, files, decisions; read after compaction |
| `research.md` | `sprint start` step 6 (normal, brief) or step 7 (high-risk/brownfield, full orient) | no — sprint doesn't gate on it, but expected before `## Approach` is drafted | Objective truth compression: relevant files, system model, constraints, unknowns |
| `review-notes.md` | `sprint complete` (normal+ tier; skipped for `Tier: bugfix`, which drops the advisory reviewer) | no — advisory reviewer gate; written for normal+ but not CLI-gated (the evaluator's `eval-report.md` is the binding one) | Advisory reviewer findings — code quality, scope, standards violations — with a YES/NO verdict |
| `eval-report.md` | `sprint complete` (non-trivial tiers — bugfix, normal, high-risk) | yes for non-trivial tiers — the evaluator run-id field must be present and the verdict line must be `pass:` (any criterion graded `partial` forces that line to `fail:`, so a non-`pass:` verdict blocks — there is no separate `partial:` verdict line); skipped only if `Tier: trivial` | Adversarial per-criterion grades (pass/fail/partial) with `file:line` evidence, written by the fresh evaluator subagent |
| `mutation-report.md` | `sprint complete` step 3 (advisory; only when logic files changed) | no — advisory only, never close-gated | Surviving mutants (tests that cannot fail) reported by the `mutation-test` skill; renders as a doc tab like any companion `.md` |
| `summary.md` | `sprint complete` step 8 | yes — must exist before close | Plan-vs-actual table; one row per acceptance criterion |

**Scenario-backed criteria (`t-c67e`).** A `## Criteria` item in `acceptance.md` may be
*scenario-backed* — it carries a Given/When/Then block, either inline (` ```gherkin `, `t-6e32`)
or a reference to a ticket-local `.feature` (` ```gherkin-file `, `t-f89a`). When it is, `## Test
Plan` **must** name the exact runner command that executes the scenario, because the evaluator
grades that criterion by running the command and reading its exit code (`pass` iff `0`), not by
reading prose — see `skills/sprint/reference/eval.md` step 6. A ` ```gherkin-file ` reference may
also carry a `runner: <cmd>` line inside the fence (`t-6f8e`) — the structured home for that
command: the board renders the resolved `<runner> <feature-path>` beneath the scenario panel
(display only, never executed by the board) and the evaluator forms and runs that same command.
Such criteria must be locked at the
sprint-start approval gate before implementation. This is additive; prose criteria are unchanged.

**Optional `Gate model:` field.** `plan.md`'s `## Sign-off` line can carry a third segment,
`Tier: <tier> | Risk: <one line> | Gate model: <value>`, to force the `sprint complete`
reviewer/evaluator dispatches onto a specific model — `<value>` is a model id (`haiku`,
`opus`, etc.) or the literal `session` to force full session-model review. Absent by
default; the skeleton `plan.md` carries a commented hint showing the syntax. Settable by
asking the agent ("run review/eval on haiku") or by hand-editing the line directly. See
`skills/sprint/reference/complete.md`'s "Model tier for gates" for how it's applied.

**Doc-less tickets** — tickets with no sprint docs are valid (e.g. backlog items, tasks that don't need a sprint), but closing one requires an explicit `tkt close <id> --no-sprint` — there is no silent default. The board renders the ticket body in the modal instead of doc tabs.

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

## Read/Write Rules

- `tkt` owns `ticket.md` — fields are written only via `tkt create`, `tkt start`, `tkt close`, `tkt reopen`. Agents must not edit `ticket.md` frontmatter directly.
- Sprint docs are agent-owned — the agent creates and edits `acceptance.md`, `plan.md`, `research.md`, `summary.md`.
- Closed tickets — `sprint complete` runs `tkt close` internally (its own gates already passed). A bare `tkt close <id>` refuses unless `--no-sprint` is passed: it errors toward `sprint complete` if sprint docs exist, or toward `sprint start`/`--no-sprint` if they don't. This sets `status: closed` and removes `ACTIVE`. Sprint docs become read-only on the board. The agent must not reopen a ticket after close without explicit user instruction.
- ACTIVE file — `.tickets/ACTIVE` contains exactly one ticket ID when a sprint is in progress. `tkt start` writes it; `tkt close` removes it. Only one sprint may be active at a time.
- Mockup promotion (any turn, any session) — if a message names an already-saved `visuals/<name>.<ext>` candidate to promote into `acceptance.md` (e.g. "use option B"), the promotion must be a real markdown image embed — `![alt](visuals/<name>.<ext>)` — never a bare or backticked filename mention. This holds independent of `sprint start`'s own steps, which only run once per sprint; a later promotion message isn't one of them.

## DECISIONS.md record contract

`DECISIONS.md` lives at the repo root and records durable choices future sprints must respect (see
`skills/sprint/SKILL.md`'s `## DECISIONS.md` and `complete.md` step 6). One row per decision in a
`| Date | Decision | Reason |` table; newest on top; write the WHY, not the what.

**Supersession — two mechanisms, by scope:**

- **Whole-entry supersession → archive-move.** When a later decision retires an *entire* earlier
  entry, move that row out to `DECISIONS-archive.md`. `start.md` step 5's decision-scan excludes the
  archive file, so an archived decision can never be resurfaced as a live constraint. This keeps the
  actively-scanned `DECISIONS.md` from growing unbounded. Never split a multi-topic entry to archive
  part of it.
- **Fragment supersession → inline `superseded-by:` marker.** When a later decision retires only
  **one fragment** of a composite, multi-topic entry (whose other topics stay live), the entry cannot
  be archive-moved or split. Instead, append `superseded-by: <YYYY-MM-DD>` (the retiring decision's
  date) to that entry's Reason cell, naming the retired fragment. The entry stays in `DECISIONS.md`;
  the marker makes the dead fragment greppable and instructs `start.md` step 5's scan to skip it —
  so a fresh agent will not resurrect the retired fragment. Prefer writing atomic, single-topic
  entries in the first place, so the cleaner whole-entry archive-move applies and this marker is
  rarely needed.
