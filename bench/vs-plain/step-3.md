Bug report for the to-do app in `todo.js`:

`node todo.js list --overdue` is wrong. With today set to 2026-03-10, it lists a to-do due 2026-03-10, but a to-do due today is not overdue yet. It also lists to-dos I have already marked done, which can never be overdue.

Fix it so `--overdue` lists only open to-dos due before today. Everything else must keep working as it does now.
