---
name: todo-hooky
description: Checks that edits to the ToDo app's index.html keep its required ids and empty-state text. Use after changing index.html in the ToDo app.
hooks:
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "echo 'todo-hooky: index.html edited, re-check the required ids'"
---

# ToDo edit check

After any edit to `index.html`, confirm that:

- the ids `todo-form`, `todo-input`, and `todo-list` are all still present exactly once;
- the empty state still reads "No todos yet.";
- the delete button still has the class `delete`.

Report each check as pass or fail with the line that proves it. Do not fix anything unless asked.
