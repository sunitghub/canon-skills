# 04 - Implementation

After approval, the agent implements against `.tickets/<id>/plan.md`.

For this walkthrough, the agent should create this small project layout:

```text
package.json
scripts/
  serve.mjs
src/
  index.html
  styles.css
  app.js
tests/
  todo.test.mjs
```

`package.json` should be an ES module package with:

```json
{
  "type": "module",
  "scripts": {
    "test": "node --test tests/*.test.mjs",
    "serve": "node scripts/serve.mjs"
  }
}
```

## Step 1 - Implement

Tell the agent to implement the approved plan. The app should stay small: add
Todo, ignore blank titles, and toggle complete/open.

Keep `sprint-check` open while the agent works. The ticket stays In Progress;
the readiness label should be `ready` once Acceptance and Plan both have useful
content, even before the unchecked acceptance items are done.

## Step 2 - Run the Test Plan

Type this in the command line after the agent creates `package.json`:

```bash
npm test
```

This is where Layer 2, knowledge capture, matters. Add one deliberate capture so
the walkthrough shows how canon preserves a useful discovery outside the chat
transcript. Tell the agent:

```text
Capture this: the Todo app is served from src/ by a tiny Node static server and tests exercise src/app.js directly, so keep browser behavior and testable logic separated unless a later ticket changes the structure.
```

The agent records that kind of discovery in `HANDOFF.md ## Discoveries`, where a
future session can recover it. Do not add another sprint doc; useful discoveries
feed the handoff context.

After tests pass, the agent produces a build summary confirming what shipped, all
acceptance criteria met, and the human-in-the-loop checkpoint recorded:

![Agent build-and-verify summary](../assets/agent-built-verified.png)

The agent will then ask whether to proceed to `sprint complete`:

![Agent asking to proceed to sprint complete](../assets/agent-ask-sprint-complete.png)

**Say not yet.** There are walkthrough steps remaining before closeout. Reply:

```text
Not yet. I want to go through the remaining walkthrough steps first.
```

Before moving on, run the app to confirm it works in the browser:

```bash
npm run serve
```

The serve command uses Node, not Python, so the Windows workshop path stays
compatible with VS Code on Windows without WSL.

![npm run serve terminal output](../assets/serve-terminal.png)

Then open `http://127.0.0.1:4173`:

![Todo app running in browser](../assets/todo-app-browser.png)

The important canon habit is that tests come from `.tickets/<id>/acceptance.md`,
not from memory. If scope changes, update the ticket before treating the work as
done.

## Step 3 - Exit And Come Back

Simulate the thing canon is built for: losing the current chat context.

1. Tell the agent to wrap up the partial state:

```text
Pause here and update HANDOFF.md with current focus, in-progress files, the captured discovery, and next steps.
```

   Check `HANDOFF.md` to confirm the discovery and next steps were captured:

   ```bash
   cat HANDOFF.md
   ```

   ![HANDOFF.md showing Discoveries and Next Steps](../assets/handoff-discoveries.png)

2. End the agent session.
3. Start a fresh agent session in `examples/canon-todo-walkthrough`.
4. Ask:

```text
Open sprint-check and tell me where the Todo sprint left off. Don't proceed yet — I want to review the state first.
```

---

**Next → [05-sprint-complete.md](05-sprint-complete.md)**

Expected result: the agent should know the active ticket, what was built, what
still needs testing, and the captured `src/` structure discovery without you
re-explaining the sprint. `sprint-check` should show the same Current Focus in
the sidebar.

> **Important:** Do not say "resume" or "continue" here — that gives the agent
> permission to run wrapup and close the sprint. The goal is to verify it can
> re-orient from `HANDOFF.md` alone, not to finish the work.

If the board already has older tickets, the returning agent should use them as
bounded context: active and open tickets first, then only recent or file-related
closed tickets. The goal is "enough state to continue," not replaying the whole
project history.

## Step 4 - Update Acceptance

As criteria pass, have the agent update `.tickets/<id>/acceptance.md` from
unchecked to checked. Reload `sprint-check` so the ticket shows progress instead
of jumping straight from not ready to closeout. You can update the checkboxes in
the board's inline editor or let the agent edit the markdown file.

Do not check an item just because code was written. Check it only after the
behavior or command has been verified.

## Step 5 - Commit With The Ticket Id

After tests pass, commit the Todo app with the ticket id in the message:

```bash
git add package.json src tests
git commit -m "t-xxxx feat: build todo list"
```

Reload `sprint-check` and click the commit in the sidebar. The commit panel
should show the changed files and connect the commit back to the ticket.

Now try the same history from the search surface:

1. Switch the board query mode from `Search` to `Why`.
2. Enter `src/app.js`.
3. Confirm the board shows the Todo ticket and any Plan decision excerpt that
   explains why that file exists.

This is the visual version of `tkt why src/app.js`: same archaeology goal, but
kept inside the sprint-check workflow.
