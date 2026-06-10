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
- A high-impact "delete all" variant caught before code, where risk ratings become required tests and a human checkpoint before close.
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
mandatory tests and any required human checkpoint to the two sprint docs.

## Agentic Coding Concerns Covered

Practical concerns with Agentic Workflows are called out such as guardrails, human-in-the-loop review,
observability, clear context, feedback, and treating AI-generated code as a
reviewed first draft. This walkthrough shows those in the app flow rather than
as a separate process:

| Concern | Where it shows up |
|---|---|
| Guardrails | `sprint start` classifies risk before code; `sprint complete` refuses unchecked criteria or tests. |
| Human-in-the-loop | Step 2's delete-all variant requires approval scope before implementation. |
| Observability | `sprint-check` exposes ticket state, docs, git status, commits, and readiness. |
| Right context | `HANDOFF.md`, `DECISIONS.md`, and the active ticket survive fresh sessions. |
| Feedback | The reviewer corrects criteria, answers grill questions, and rejects risky scope in chat. |
| Review and tests | Acceptance and Test Plan checkboxes must be verified before close. |

## Walk The Canon Flow

1. Copy the walkthrough files into a destination folder by running this script:
   ```bash
   ~/.canon/scripts/copy-todo-walkthrough.sh <path_to_dest_folder>
   cd <path_to_dest_folder>
   ```
2. Read [01-setup.md](steps/01-setup.md) — wire the tools.
3. Start the sprint in [02-sprint-start.md](steps/02-sprint-start.md) — describe the work; the agent plans it.
4. Use the board checkpoint in [03-sprint-check.md](steps/03-sprint-check.md) — review what the agent drafted.
5. Build and test with [04-implementation.md](steps/04-implementation.md) — implement and tick off criteria.
6. Complete the sprint with [05-sprint-complete.md](steps/05-sprint-complete.md) — close with the gate, including the failure case.

The finished reference implementation lives in [`../todo-app`](../todo-app).
