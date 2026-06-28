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

Drag the bottom-right corner of the ticket detail modal to resize it when long Description, Acceptance, or Plan content needs more room. Press `Esc` to close the modal.

Closed and discarded tickets open read-only. Their sprint docs remain inspectable, but edit controls are hidden until the work is reopened or a new ticket is created.

## Edit Sprint Docs in Place

![Edit sprint docs in ticket detail](../meta/screenshots/ticket-doc-editor.png)

Open a ticket to read or edit its Description, Acceptance, and Plan without leaving the board. Docs with two or more `##` sections show a sticky jump bar at the top — click any heading to scroll straight to it.

## Ticket Search

![sprint-check board — searchable local kanban](../meta/screenshots/sprint-check-board-dark.png)

Use the search box above the columns to find tickets by title, id, status, type, priority, description, doc names, or readiness labels such as `plan incomplete`. Matching tickets stay in their original lanes so status context is preserved. Press `Esc` or clear the field to restore the full board.

Switch the segmented control from `Search` to `Why` to ask why a file exists or
changed. Enter a project-relative file path and sprint-check scans git history,
matches tickets, and shows Plan decision excerpts above the board. You can also
type `why:path/to/file` as a shortcut.

## Commit Intelligence

![Commit detail with related ticket](../meta/screenshots/commit-detail.png)

Click any commit in the sidebar to see what changed and which ticket it likely belongs to — matched by ticket ID in the commit message or by keyword when no ID is present.

## Create Tickets from the Board

![New ticket modal](../meta/screenshots/new-ticket.png)

`+ New` opens a form pre-filled with a structured template. The title suggests a type automatically — feature, task, bug, chore, or epic — while leaving type, priority, and description editable before `Create`. The ticket lands in `.tickets/<id>/ticket.md`, immediately visible to your agent.

## Ticket Completeness

![Ticket completeness checker](../meta/screenshots/ticket-completeness.png)

Every card shows a readiness indicator:

- **● ready** (green) — Acceptance and Plan both present; Acceptance has real items under `## Criteria` and `## Test Plan`, Plan has real notes under `## Approach`, and `plan.md ## Sign-off` has a checked approval item.
- **● incomplete** (red) — Acceptance doc exists but one or both required sections have no checklist items. This mirrors a CLI-enforced `sprint complete` close gate. Opening the Acceptance tab shows an inline warning naming the empty sections.
- **● plan incomplete** (red) — Plan exists but `## Approach` is empty or still contains the template placeholder. This is board-surfaced early warning; the CLI also blocks close if `## Approach` has no real content. A short real approach is enough; Decisions can stay empty for simple work.
- **● needs acc / needs plan / needs signoff** (amber) — the next doc or approval item to add.

Click or hover the indicator for a checklist popover. Acceptance and Sign-off readiness mirror CLI close gates; Plan readiness is an early board signal so untouched templates show up while you're working. The board never judges whether a checked item is true — that remains agent-required verification and evaluator review.

## Drag to Update Status

![Drag and drop ticket](../meta/screenshots/drag-drop.png)

Drag any ticket card between columns to update its status. The board enforces two gates: dragging to **Done** is blocked if any acceptance criteria checkbox is unchecked (a toast explains why); dragging to **In Progress** without an acceptance doc shows an amber warning but allows the move. All other drags apply immediately.

## Attach Docs to a Ticket

![New doc dialog](../meta/screenshots/new-doc.png)

Click `+ New doc` on any ticket to attach a structured document. Two docs cover the full sprint:

| Doc | Add when | Use it to |
|---|---|---|
| **Acceptance** | First | `## Criteria` and `## Test Plan` sections both need checklist items — `sprint complete` blocks without them |
| **Plan** | After acceptance | Capture the approach and record decisions as you build — readable by future agents |

Sprint docs land in `.tickets/<id>/` as markdown files and are read automatically by your agent after sprint start. Templates include comments that mark which headings and ticket ID lines should stay unchanged, and the editor toolbar inserts common Markdown such as checkboxes, bullets, numbered items, headings, inline code, and toggle blocks at the cursor.

Once both Acceptance and Plan exist, `+ New doc` is hidden. Other workflow outputs are handled by the agent or by repo-local context files; they are not extra sprint docs to create from the board.

## How Sprint Works

One workflow command drives the lifecycle. The CLI handles deterministic state; the agent chooses the lightest tier that protects the work — trivial changes skip sprint, normal changes get a brief ticket/acceptance/plan path, and high-risk changes run the full sub-skill pipeline. The two diagrams on the [README](../README.md#how-sprint-works) show the start and complete flows.

Enforcement layers:

- **CLI-enforced:** ticket state, one active sprint, required sprint files, required checklist items, unchecked boxes, `summary.md`, `## Wrapup Gates`, plan Approach content, and eval verdict presence.
- **Agent-required:** tier classification, orientation, gray-area resolution, impact analysis, wrapup review/audit steps, test judgment, acceptance judgment, and invoking clean-context eval.
- **Board-surfaced:** readiness indicators, inline warnings, ticket docs, commit/ticket context, and early visibility before the close gate runs.

Recommended order: create `acceptance.md` first to define Done, then `plan.md` to capture the approach and decisions. `sprint-check` suggests that order in `+ New doc`.

Only those markdown files are sprint docs the user or agent creates. The double-bordered steps in the diagrams are sub-skills used when the tier calls for them: `orient` reads the codebase and feeds findings into the Plan, `impact-analysis` rates risk and feeds the test plan (detailed below), and `capture` writes notable discoveries to `HANDOFF.md` when they appear mid-build. On `sprint complete`, `code-simplifier`, `code-reviewer`, `security-review`, `repo-check`, and `doc-audit` are considered in order, using skip rules for steps that do not apply. Then `eval` runs as a fresh subagent — no implementation history — and grades each acceptance criterion against the actual code from a clean context window; a fail or partial verdict blocks close. These all run as part of the `sprint` workflow; they are not separate docs to create and not commands the user has to invoke.

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
