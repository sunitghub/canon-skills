# 04 - Implementation

After approval, the agent implements against `.tickets/<id>/plan.md`.

For this walkthrough, the agent should create this small project layout:

```text
package.json
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
    "serve": "python3 -m http.server 4173 -d src"
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

## Step 3 - Update Acceptance

As criteria pass, have the agent update `.tickets/<id>/acceptance.md` from
unchecked to checked. Reload `sprint-check` so the ticket shows progress instead
of jumping straight from not ready to closeout. You can update the checkboxes in
the board's inline editor or let the agent edit the markdown file.

Do not check an item just because code was written. Check it only after the
behavior or command has been verified.

## Step 4 - Run the App

Type this in the command line:

```bash
npm run serve
```

Then open `http://127.0.0.1:4173`.

The important canon habit is that tests come from `.tickets/<id>/acceptance.md`,
not from memory. If scope changes, update the ticket before treating the work as
done.

## Step 5 - Commit With The Ticket Id

After tests pass, commit the Todo app with the ticket id in the message:

```bash
git add package.json src tests
git commit -m "t-xxxx feat: build todo list"
```

Reload `sprint-check` and click the commit in the sidebar. The commit panel
should show the changed files and connect the commit back to the ticket.
