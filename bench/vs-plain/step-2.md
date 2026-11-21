Add due dates and filters to the to-do app in `todo.js`. Everything it does today keeps working the same way.

- `add "<text>" --due YYYY-MM-DD` saves a due date with the to-do. A date that is not a real calendar date in that exact form (`2026-02-30`, `2026-1-5`, `tomorrow`) is an error: a one-line message on stderr, exit 1, nothing saved.
- `list` shows a to-do's due date at the end of its line: `#<id> [ ] <text> (due YYYY-MM-DD)`. A to-do without one is shown as before.
- `list --open` lists only open to-dos, and `list --done` only done ones.
- `list --overdue` lists only open to-dos whose due date is before today. Today is the date in the `TODO_TODAY` environment variable (YYYY-MM-DD) when it is set, otherwise the local date.
- When a filter matches nothing, `list` prints `No todos.`
