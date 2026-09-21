---
name: todo-conventions
description: Conventions for the ToDo app's item text and for changing its single-file index.html. Use when writing or rewriting todo items, or when adding, persisting, or restyling anything in the ToDo app.
---

# ToDo conventions

## Item text

- Imperative verb first: "Buy milk", not "I should buy milk" or "Milk".
- 60 characters or fewer. If a request is longer, shorten it and say what you cut.
- Sentence case, no trailing period, no filler ("probably", "maybe", "I need to").
- One action per item. Split "Call Sam and book flights" into two items.

## Changing the app

- The app is one file, `index.html`. Do not add a build step, framework, or extra files.
- Keep the DOM ids `todo-form`, `todo-input`, and `todo-list`. Tests and tooling look them up, so never rename them; suggest a wrapper element or a class instead.
- State lives in the in-memory `todos` array (`{ text, completed }`). It resets on reload by design.
- Persistence is opt-in. Only add it when the user asks, using `localStorage` under the key `todo:v1`, storing the `todos` array as JSON, with reads and writes wrapped in `try`/`catch` so a blocked storage never breaks rendering.
- The empty state text is exactly "No todos yet." and the delete button keeps the class `delete`.
