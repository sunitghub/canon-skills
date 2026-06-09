# Canon Todo Walkthrough

This walkthrough shows canon's sprint flow end-to-end by building a minimal Todo
app from scratch. It is designed so that anyone — developer or not — can follow
the steps and understand what each tool does and why.

**What you'll see:**
- A ticket created with a single command; the board shows it instantly.
- The agent drafts the "done criteria" and test plan for you to review, not the other way around.
- The board flags incomplete Acceptance or Plan docs before you try to close or build from a placeholder.
- Session continuity through `HANDOFF.md`, including a stop-and-resume checkpoint.
- A user-triggered capture for a Todo-specific discovery found while building.
- A high-impact "delete all" variant caught before code, where risk ratings become required tests before close.
- Ticket search, readiness indicators, inline doc editing, status changes, git state, and commit context in `sprint-check`.
- Closing the sprint is gated: the CLI checks the board's criteria and test plan are both filled and ticked.

A developer runs the terminal commands. A product manager reads the board and
reviews the acceptance criteria the agent drafts. Both roles are shown.

The folder starts with docs only. Setup creates the local `.tickets/` project
marker, `sprint start` creates ticket state, and the implementation step creates
the app files.

Canon uses two sprint docs:

| Doc | Purpose |
|---|---|
| `acceptance.md` | Done criteria, test plan, and QA sign-off |
| `plan.md` | Approach and decisions |

Other canon layers feed those docs or the local board instead of creating extra
files to manage: session continuity uses `HANDOFF.md`, durable decisions use
`DECISIONS.md`, capture records discoveries, and high-risk impact analysis adds
mandatory tests to Acceptance.

## Walk The Canon Flow

1. Read [01-setup.md](01-setup.md) — wire the tools.
2. Start the sprint in [02-sprint-start.md](02-sprint-start.md) — describe the work; the agent plans it.
3. Use the board checkpoint in [03-sprint-check.md](03-sprint-check.md) — review what the agent drafted.
4. Build and test with [04-implementation.md](04-implementation.md) — implement and tick off criteria.
5. Complete the sprint with [05-sprint-complete.md](05-sprint-complete.md) — close with the gate, including the failure case.

The finished reference implementation lives in [`../todo-app`](../todo-app).
