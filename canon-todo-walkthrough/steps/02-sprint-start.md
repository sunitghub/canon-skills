# 02 - Sprint Start

**What this step does:** The agent plans the work *before* writing any code. You
describe the outcome in one sentence; the agent drafts the done criteria and
test plan for you to review. Nothing is built until you approve.

```mermaid
flowchart LR
    T[Ticket] --> A[Acceptance] --> O[[orient]]
    O --> G[Grill] --> I[[impact]] --> AP[Approval] --> P[Plan]
    classDef subskill stroke:#8888dd,stroke-width:2px
    class O,I subskill
```

Steps in plain English:
- **Acceptance** — the agent writes the checklist of "done" criteria and test commands.
- **Orient** *(runs automatically)* — the agent reads the codebase to understand what already exists.
- **Grill** — the agent asks you the questions that change what gets built (see Step 5 below).
- **Impact** *(runs automatically)* — the agent rates the risk of the change.
- **Approval** — you say "approved" and the agent locks in the plan.
- **Plan** — the final brief the agent implements against; only written after your approval.

## Step 1 - Open the empty board

```bash
sprint-check
```

Zero open, zero active, empty columns — the expected start for a new project.

## Step 2 - Describe the work

In your agent session:

```bash
sprint start "Build a simple Todo list"
```

The CLI creates the ticket and active state:

```text
.tickets/<id>/ticket.md
DECISIONS.md
HANDOFF.md
```

Then the agent takes over: it drafts **Acceptance** (done criteria + test plan),
reads the codebase, and surfaces gray-area questions. It also classifies the
risk tier. A small local Todo app is normal-tier work, so the plan stays brief;
a high-risk variant like "bulk delete every user's tasks" would trigger impact
analysis before approval, and any HIGH risk would add mandatory mitigation tests
to Acceptance. After approval, the agent writes **Plan** (approach + decisions).

Reload `sprint-check`. The ticket is In Progress and `not ready` — only
`ticket.md` plus any drafted sprint docs exist so far. Open it to read what the
agent proposed.

![sprint-check board after sprint start](../assets/sprint-start-board.png)

> Your agent's wording will differ from the samples below — that's expected. What
> stays constant: Acceptance is binary and testable, and `plan.md` is written only
> after you approve.

## Step 3 - Review what the agent drafted

Click on the ticket card to open it. You'll see the **Description** tab selected by default:

![Ticket open on Description tab](../assets/ticket-description-tab.png)

Click **Acceptance** to see the done criteria and test plan the agent drafted:

![Ticket open on Acceptance tab](../assets/ticket-acceptance-tab.png)

Click the **×** in the top-right corner to close the ticket and return to the board.

The Acceptance the agent produces should read like this:

```markdown
## Criteria
- [ ] Users can add a non-empty Todo item.
- [ ] Blank Todo titles are ignored.
- [ ] Users can mark a Todo complete and back open.


## Test Plan
### Functional tests
- [ ] `npm test` — covers add, blank-title rejection, and com
plete/open toggle

### Impact tests
- [ ] None — no HIGH-rated dimensions.

### Regression tests
- [ ] None — greenfield; no prior tickets touched these files

```

**What to look for:** Every item should be something you can verify by running
the app or running the tests — not vague prose. If a criterion is missing or
wrong, tell the agent in chat. Don't hand-edit the doc yourself; the point is
that acceptance reflects a shared agreement.

If the board shows `incomplete` on the card, it means the agent left an
Acceptance section empty. Tell the agent to fill it before you approve.

For this Todo sprint, the test plan is intentionally small. That is the point of
canon's impact layer: low-risk work stays light, while irreversible, broad, or
multi-trigger work earns extra tests before code starts.

## Step 4 - Try a high-impact variant

Before approval, deliberately ask about a riskier version:

```text
What if this Todo app also has a Delete all todos button with no undo?
```

The agent should catch the impact before code is written. Even in a local demo,
that request changes the risk profile: **Reversibility** is HIGH because the
action destroys user-entered state, and **Trigger paths** may become relevant if
the same delete handler is reachable from multiple controls.

The agent should respond by adding mitigations to Acceptance, such as:

```markdown
- [ ] Delete-all requires explicit confirmation.
- [ ] Delete-all can be cancelled without changing the list.
- [ ] No alternate trigger path bypasses the confirmation.
- [ ] Human approval recorded for HIGH-impact change before implementation.
```

It should also record the approval boundary in `plan.md`, not in a new doc:

```markdown
### Human checkpoint
- Required: yes
- Decision needed: whether delete-all is in scope and what autonomy is allowed
- Human resolution: rejected for this sprint; keep original Todo scope
- Approved autonomy: implement only the approved simple Todo list and run tests
```

For the walkthrough, reject the risky variant and keep the original simple Todo
scope:

```text
Good catch. Do not add delete-all in this sprint. Keep the original scope.
```

This is the human-in-the-loop moment. The agent can analyze and propose
mitigations, but it does not get autonomous permission to add an irreversible
operation just because it can generate the code.

The agent should confirm the rejection, record the checkpoint in `plan.md`, and surface its remaining question:

![Agent response after rejecting delete-all](../assets/agent-reject-deleteall.png)

## Step 5 - Answer the grill, then approve

After drafting, the agent asks the questions that change what gets built. These
are the things that have no right answer without your input — for example:
*"Should completed Todos be toggleable back to open?"*

Answer the grill question in chat:

```text
Yes, allow toggling completed Todos back open. Keep it framework-free.
```

Then approve:

```text
Go ahead.
```

On approval the agent writes `plan.md`. For normal-tier work, the agent fills in
the `## Sign-off` risk summary and checks the approval box itself:

```markdown
## Sign-off
Tier: normal | Risk: low — greenfield local Todo app, no shared state or irreversible ops

- [x] Plan approved — proceed to implementation
```

`## Sign-off` is always the first section of `plan.md`. On the board, it appears
as the first jump link in the Plan tab's sticky nav — so the approval state is
visible at a glance before reading the approach.

For high-risk work (such as the delete-all variant from Step 4), the agent leaves
Sign-off **unchecked**. The pre-commit hook blocks commits until you open
`plan.md` in the board's Plan tab and check the box yourself. The risk summary
line tells you what you're signing off on.

The ticket stays In Progress, now with Acceptance and Plan present and
ready to build.

Reload `sprint-check`. The card status should now show **READY** — all artifacts (Acceptance + Plan) are in place:

![Board showing ticket READY status](../assets/board-ready.png)

Click the card, then click **Plan** to see the approved brief the agent will implement against:

![Ticket open on Plan tab](../assets/ticket-plan-tab.png)

---

**Next → [03-sprint-check.md](03-sprint-check.md)**
