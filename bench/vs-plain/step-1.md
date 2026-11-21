Build a small to-do list command-line app in Node.js (version 22 or later), with no npm dependencies.

The program is `todo.js` in the project root and runs as `node todo.js <command> [args]`.

Commands:
- `add "<text>"`: adds an open to-do and prints `Added #<id>: <text>`. Ids are whole numbers starting at 1. Each new to-do takes one more than the highest id ever used, so ids are never reused, even after a remove.
- `list`: prints one line per to-do in id order, `#<id> [ ] <text>` for an open one and `#<id> [x] <text>` for a done one. When there are none it prints `No todos.`
- `done <id>`: marks the to-do done and prints `Done #<id>`.
- `remove <id>`: deletes the to-do and prints `Removed #<id>`.

The to-dos are saved as JSON in the file named by the `TODO_FILE` environment variable, or in `todos.json` in the current folder when it is not set. A missing file means an empty list.

Errors: an unknown command, a missing or empty text, or an id that is not a whole number or does not exist prints a one-line message on stderr and exits with status 1, changing nothing. Success exits 0.
