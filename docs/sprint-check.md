# Sprint-Check — Feature Tour

`sprint-check` opens a local kanban board from your project's `.tickets/` folder and `git log` — no hosted server, no account, no SaaS. Run it from your project root:

```bash
sprint-check
```

See the [README](../README.md#the-board) for the overview. This page walks through each feature with a screenshot.

## Dark Mode

![sprint-check board — dark mode](../meta/screenshots/board-dark.png)

Toggle between light and dark with the button in the top-right corner.

## Ticket Detail

![Ticket detail modal](../meta/screenshots/ticket-detail.png)

Click any ticket to see its status, type, priority, readiness, description, and attached docs in one place.

## Edit Sprint Docs in Place

![Edit sprint docs in ticket detail](../meta/screenshots/ticket-doc-editor.png)

Open a ticket to read or edit its Description, Acceptance, and Plan without leaving the board.

## Commit Intelligence

![Commit detail with related ticket](../meta/screenshots/commit-detail.png)

Click any commit in the sidebar to see what changed and which ticket it likely belongs to — matched by ticket ID in the commit message or by keyword when no ID is present.

## Create Tickets from the Board

![New ticket modal](../meta/screenshots/new-ticket.png)

`+ New ticket` opens a form pre-filled with a structured template. The title suggests a type automatically — feature, task, bug, chore, or epic — while leaving type, priority, and description editable before `Create`. The ticket lands in `.tickets/<id>/ticket.md`, immediately visible to your agent.

## Ticket Completeness

![Ticket completeness checker](../meta/screenshots/ticket-completeness.png)

Every card shows a readiness indicator. Three states:

- **● ready** (green) — Acceptance and Plan both present; Acceptance has real items under `## Criteria` and `## Test Plan`, and Plan has real notes under `## Approach`.
- **● acceptance incomplete** (red) — Acceptance doc exists but one or both required sections have no checklist items. `sprint complete` will block. Opening the Acceptance tab shows an inline warning naming the empty sections.
- **● plan incomplete** (red) — Plan exists but `## Approach` is empty or still contains the template placeholder. A short real approach is enough; Decisions can stay empty for simple work.
- **● needs acceptance / needs plan** (gray) — the next doc to add.

Click or hover the indicator for a checklist popover. Acceptance readiness mirrors the CLI close gate; Plan readiness is an early board signal so untouched templates show up while you're working.

## Drag to Update Status

![Drag and drop ticket](../meta/screenshots/drag-drop.png)

Drag any ticket card between columns to update its status instantly. No clicks, no dropdowns — the board writes the change back to `.tickets/` immediately.

## Attach Docs to a Ticket

![New doc dialog](../meta/screenshots/new-doc.png)

Click `+ New doc` on any ticket to attach a structured document. Two docs cover the full sprint:

| Doc | Add when | Use it to |
|---|---|---|
| **Acceptance** | First | `## Criteria` and `## Test Plan` sections both need checklist items — `sprint complete` blocks without them |
| **Plan** | After acceptance | Capture the approach and record decisions as you build — readable by future agents |

Sprint docs land in `.tickets/<id>/` as markdown files and are read automatically by your agent after sprint start. Templates include comments that mark which headings and ticket ID lines should stay unchanged, and the editor toolbar inserts common Markdown such as checkboxes, bullets, numbered items, headings, inline code, and toggle blocks at the cursor.

## How Sprint Works

One workflow command drives the lifecycle. The CLI handles deterministic state; the agent chooses the lightest tier that protects the work — trivial changes skip sprint, normal changes get a brief ticket/acceptance/plan path, and high-risk changes run the full sub-skill pipeline. The two diagrams on the [README](../README.md#how-sprint-works) show the start and complete flows.

Recommended order: create `acceptance.md` first to define Done, then `plan.md` to capture the approach and decisions. `sprint-check` suggests that order in `+ New doc`.

Only those markdown files are sprint docs the user or agent creates. The double-bordered steps in the diagrams are sub-skills used when the tier calls for them: `orient` reads the codebase and feeds findings into the Plan, `impact-analysis` rates risk and feeds the test plan (detailed below), and `capture` writes notable discoveries to `HANDOFF.md` when they appear mid-build. On `sprint complete`, `code-simplifier`, `code-reviewer`, `security-review`, `repo-check`, and `doc-audit` are considered in order, using skip rules for steps that do not apply. They run as part of the `sprint` workflow; they are not separate docs to create and not commands the user has to invoke.

### Impact Analysis — five dimensions

For high-risk work, `sprint start` rates the change across five risk dimensions and writes the result to the Plan:

| Dimension | Asks |
|---|---|
| **Audience** | Who and how many does this reach — one user, a tenant, everyone, or external systems? |
| **Reversibility** | Can it be undone, or does it delete, send, or write money permanently? |
| **Blast radius** | If it fails, is the damage contained or does it corrupt shared state? |
| **Trigger paths** | How many UI paths, API callers, or jobs reach the same handler? |
| **Cascade risk** | What downstream consumers — queues, tables, external APIs — react to the change? |

Each dimension is rated HIGH, MEDIUM, or LOW. The ratings aren't advisory: **every HIGH adds required mitigation to the acceptance plan** — a rollback test for permanent operations, a handler-binding grep and server-side auth check for multiple trigger paths, a per-consumer test for cascade risk, an audit-log requirement for broad audience — and the `sprint complete` gate refuses to close while any of those items is still unchecked in `acceptance.md`. The gate checks box state, not the work behind it — the agent verifies each mitigation actually holds before checking it. Normal-tier changes record that no high-risk trigger was found and proceed with a shorter plan.

**Regression carryover.** `sprint start` also scans `.tickets/` for closed tickets that touched the same files this sprint will modify, and adds one regression test per match. Past work that passed stays passing — the test obligation rides along automatically, so a later change can't silently break behavior an earlier ticket established.
