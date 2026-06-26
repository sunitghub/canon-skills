# 05 - Sprint Complete

**What this step does:** The CLI verifies acceptance is complete before closing
the ticket. It is a hard gate — the close command will print what is missing and
refuse to proceed until the doc is fixed.

## Step 1 - Confirm Acceptance

Before closing, `.tickets/<id>/acceptance.md` must have:
- At least one checked item under `## Criteria`
- At least one checked item under `## Test Plan`
- No unchecked items under `## Criteria` or `## Test Plan`

`.tickets/<id>/plan.md` must also have:
- `## Sign-off` with a checked `- [x] Plan approved` box
- Real notes under `## Approach`, not the template placeholder

`acceptance.md` must also have:
- A `## Wrapup Gates` section with at least one `ran` row (written by the agent during wrapup)

Open the ticket on the board and check every item as it passes tests.

Before running `sprint complete`, open the ticket on the board and confirm all Acceptance items are checked — criteria, test plan, and QA sign-off:

![Ticket showing fully checked Acceptance](../assets/ticket-acceptance-complete.png)

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

**If `plan.md ## Approach` is still a template placeholder:**

```
$ sprint complete
Sprint t-xxxx cannot close: plan.md ## Approach has no content.
Describe the implementation approach in plan.md, then re-run.
```

Fix: open the Plan tab on the board (or edit `.tickets/<id>/plan.md` directly)
and replace the placeholder with actual notes on what was built and why.

**If the `## Wrapup Gates` section is missing from `acceptance.md`:**

```
$ sprint complete
Sprint t-xxxx cannot close: acceptance.md is missing ## Wrapup Gates section.
Run wrapup before closing.
```

Fix: tell the agent to run wrapup. It will execute the gate pipeline and append
the `## Wrapup Gates` table to `acceptance.md`. Only then will `sprint complete`
proceed. This ensures closeout cannot happen without the quality gates on record.

The board's readiness indicator also reflects this:

- `incomplete` means Acceptance has missing checklist structure.
- `plan incomplete` means Plan still has an empty or placeholder approach.

These are early warnings you can act on before running `sprint complete`.

## Step 2b - Evaluator Review

Before the agent runs `sprint complete`, it invokes an evaluator subagent with a
clean context — no implementation history, no chat transcript. The evaluator reads
`acceptance.md` and the changed files fresh, then grades each criterion against
the evidence in the code.

This is the mechanism that catches what the implementing agent misses. The agent
that built the feature is a poor judge of whether it delivered the spec — it
remembers what it intended, not what it actually tested.

Tell the agent:

```text
Run the evaluator before closing.
```

The evaluator reads the acceptance criteria, then reads `tests/todo.test.mjs`.
It finds that three criteria are checked:

```
- [x] App renders a list of todos
- [x] Add todo via input + button
- [x] Delete individual todo
- [x] Toggle complete/open
- [x] npm test passes
```

But the test file only covers add and delete:

```js
// tests/todo.test.mjs
test('adds a todo', ...) ✓
test('ignores blank titles', ...) ✓
test('deletes a todo', ...) ✓
// toggle: no test
```

The evaluator reports a partial finding:

```
## Eval Report

Ticket: t-xxxx

## Criteria

| Criterion | Status | Evidence |
|---|---|---|
| App renders a list of todos | pass | tests/todo.test.mjs:1 — initial state assertion |
| Add todo via input + button | pass | tests/todo.test.mjs:5 — addTodo covered |
| Delete individual todo | pass | tests/todo.test.mjs:14 — deleteTodo covered |
| Toggle complete/open | partial | toggle behaviour not exercised in test suite |
| npm test passes | pass | test run output in acceptance.md |

## Findings

1. "Toggle complete/open" is checked in acceptance.md but has no corresponding
   test. The feature works in the browser (agent confirmed), but the test suite
   does not verify it. A passing npm test run does not cover this criterion.

## Verdict

fail: one acceptance criterion checked without test evidence
```

The implementing agent checked "Toggle complete/open" because the feature worked
in the browser. The evaluator, reading the code cold, caught that browser
verification and tested verification are not the same thing.

**The agent now adds the missing test.** It does not reopen the ticket or change
the acceptance criterion — it adds one test case to `tests/todo.test.mjs` and
re-runs `npm test`:

```js
test('toggles a todo complete and back', () => {
  const state = { todos: [] };
  addTodo(state, 'write tests');
  toggleTodo(state, state.todos[0].id);
  assert.strictEqual(state.todos[0].complete, true);
  toggleTodo(state, state.todos[0].id);
  assert.strictEqual(state.todos[0].complete, false);
});
```

```
$ npm test
✓ adds a todo
✓ ignores blank titles
✓ deletes a todo
✓ toggles a todo complete and back
4 passing
```

The agent re-checks the "Toggle complete/open" criterion — not because the
feature now works, but because it is now tested. The evaluator re-grades and
returns a clean verdict:

```
## Verdict

pass: all acceptance criteria have test evidence or explicit verification
```

**This is the loop the evaluator is for.** Not a second pair of human eyes on
the same context, but a genuinely independent read that has no memory of what
the agent meant to do — only what the code and tests actually show.

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

Each gate in the wrapup pipeline either runs or is skipped based on what changed:

![Wrapup pipeline gates before close](../assets/wrapup-pipeline.png)

After wrapup, the agent appends a `## Wrapup Gates` section to `acceptance.md`
recording every gate's outcome. For this Todo sprint it should look like:

```markdown
## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| simplifier | skipped | clean minimal code, no simplification opportunities |
| reviewer | skipped | no design implications in greenfield app |
| security | skipped | no security-sensitive patterns (no auth, DB, user input handling, or API endpoints) |
| repo-check | skipped | no repo surface changed |
| doc-audit | skipped | no user-facing docs changed |
```

Open the ticket's Acceptance tab on the board after close to confirm the section
is there. This makes `acceptance.md` the complete record: what was tested *and*
what quality gates ran.

After the wrapup gates, the agent writes `.tickets/<id>/summary.md` containing
a **plan-vs-actual table** and a one-paragraph close summary:

```markdown
# Summary

| Acceptance item | Status | Notes |
|---|---|---|
| App renders a list of todos | delivered | — |
| Add todo via input + button | delivered | — |
| Delete individual todo | delivered | — |
| npm test passes | delivered | — |

All acceptance criteria delivered. Tests passed via `npm test`. No waivers or
deferred items. Follow-up: none.
```

`Status` is one of: `delivered`, `waived`, `deferred`, or `partial`. Anything
other than `delivered` must have a reason in Notes — deviations cannot be
buried in prose and skipped in the table.

This file appears automatically as a **Summary** tab on the ticket board,
alongside Acceptance and Plan. Open the closed ticket on the board to see it —
read-only, like the other tabs on a closed ticket. It is the permanent record
of what was delivered versus what was planned, without having to scroll back
through the chat.

For this Todo sprint, impact analysis should have stayed light because there is
no broad audience, irreversible operation, shared-state blast radius, duplicate
trigger path, or downstream cascade. If any of those were HIGH, their mitigation
tests would already be in Acceptance, and closeout would not proceed until they
were checked. If HIGH-impact approval was required, the human checkpoint item
would be checked through the same gate.

Expected output when all items are checked:

```
Sprint t-xxxx is closed.
```

## Step 4 - Verify Done

Reload `sprint-check`. The Todo ticket should now appear in Done, with the same
Acceptance and Plan tabs still available in the detail view. The ticket is
read-only in the modal because closed work should not be edited in place.

Open the Acceptance tab to confirm the Wrapup Gates section is present at the bottom:

![Acceptance tab showing wrapup gates on closed ticket](../assets/acceptance-wrapup-gates.png)

Use the search box to find the closed ticket by title or id. Then clear the
search and click the latest commit in the sidebar to confirm the final commit is
visible and connected to the ticket.
