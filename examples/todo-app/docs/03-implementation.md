# 03 - Implementation

After approval, the agent implements against the accepted sprint plan.

For this Todo app, the source layout is intentionally small:

```text
src/
  index.html
  styles.css
  app.js
tests/
  todo.test.mjs
```

Run the test plan:

```bash
npm test
```

Run the app locally:

```bash
npm run serve
```

Then open `http://127.0.0.1:4173`.

The important canon habit is that tests come from `.tickets/<id>/acceptance.md`, not from memory. If scope changes, update the ticket before treating the work as done.
