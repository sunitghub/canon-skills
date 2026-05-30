# Blueprint - Build a simple Todo list

Ticket: `t-demo`

## Goal

Build a dependency-free browser Todo app that demonstrates the canon sprint workflow.

## Files to Inspect

- `src/index.html`
- `src/styles.css`
- `src/app.js`
- `tests/todo.test.mjs`

## Files to Change

- `src/index.html`
- `src/styles.css`
- `src/app.js`
- `tests/todo.test.mjs`

## Subsystem Map

- `src/index.html` defines the app shell, form, filter controls, and list mount point.
- `src/app.js` owns Todo state transitions and browser rendering.
- `tests/todo.test.mjs` covers pure Todo behavior with Node's built-in test runner.

## Grill

- Persistence: use `localStorage` because the example should run without a backend.
- Filters: support `All`, `Open`, and `Done` because they exercise state transitions without adding routing.

## Impact Assessment

- Audience: LOW
- Reversibility: HIGH
- Blast radius: LOW
- Trigger paths: LOW
- Cascade risk: LOW

## Build Plan

1. Implement pure Todo state helpers.
2. Wire DOM rendering and localStorage persistence.
3. Add focused tests for add, toggle, filter, delete, and blank-title behavior.
4. Verify with `npm test`.
