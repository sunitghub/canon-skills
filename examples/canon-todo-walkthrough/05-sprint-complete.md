# 05 - Sprint Complete

**What this step does:** The CLI verifies acceptance is complete before closing
the ticket. It is a hard gate — the close command will print what is missing and
refuse to proceed until the doc is fixed.

## Step 1 - Confirm Acceptance

Before closing, `.tickets/<id>/acceptance.md` must have:
- At least one checked item under `## Criteria`
- At least one checked item under `## Test Plan`
- No unchecked items under `## Criteria` or `## Test Plan`

`.tickets/<id>/plan.md` should also have real notes under `## Approach`, not the
template placeholder.

Open the ticket on the board and check every item as it passes tests.

## Step 2 - See the gate in action (try it early)

You can run the close command with unchecked or missing items to see the guard.

**If Test Plan is missing or empty:**

```
$ sprint complete
Sprint t-xxxx cannot close: acceptance.md ## Test Plan has no checklist items.
Add test commands to acceptance.md, then re-run.
```

Fix: open `acceptance.md` and add at least one test command under `## Test Plan`,
then check it.

**If items are still unchecked:**

```
$ sprint complete
Sprint t-xxxx is not complete. Unchecked acceptance/test items remain:
- [ ] npm test
```

Fix: run `npm test`, confirm it passes, then have the agent check that item.

The board's readiness indicator also reflects this:

- `incomplete` means Acceptance has missing checklist structure.
- `plan incomplete` means Plan still has an empty or placeholder approach.

These are early warnings you can act on before running `sprint complete`.

## Step 3 - Complete the Sprint

Tell the agent in chat:

```text
Sprint complete
```

The agent should:

- Verify each item in `.tickets/<id>/acceptance.md`.
- Run the wrapup path proportionally: simplifier/review/security/doc checks run
  only when they apply.
- Confirm the test command passed.
- Update `DECISIONS.md` only for durable non-obvious decisions.
- Update `HANDOFF.md` with follow-up work.
- Run `sprint complete` to close the active ticket.

For this Todo sprint, impact analysis should have stayed light because there is
no broad audience, irreversible operation, shared-state blast radius, duplicate
trigger path, or downstream cascade. If any of those were HIGH, their mitigation
tests would already be in Acceptance, and closeout would not proceed until they
were checked.

Expected output when all items are checked:

```
Sprint completed: t-xxxx
```

## Step 4 - Verify Done

Reload `sprint-check`. The Todo ticket should now appear in Done, with the same
Acceptance and Plan tabs still available in the detail view. The ticket is
read-only in the modal because closed work should not be edited in place.

Use the search box to find the closed ticket by title or id. Then clear the
search and click the latest commit in the sidebar to confirm the final commit is
visible and connected to the ticket.
