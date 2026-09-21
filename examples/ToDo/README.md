# ToDo example skills

Originals of three test skills for the board's **Skill Eval** card (Upkeep view). Canon's own skills cannot be picked there, so these live outside `skills/` and are copied into a registered project (the ToDo app) to try each branch of the card.

| Skill | Shows |
|---|---|
| `todo-conventions` | Passes stages 1 and 2 (4 evals, mixed case types); stage 3 gives a real with/without score |
| `todo-no-evals` | Stage 1 fails with the "how to create evals" fix, so stage 3 stays locked |
| `todo-hooky` | Frontmatter `hooks:` raises the trust warning; Run needs the acknowledgement checkbox (the hook only runs `echo`) |

Use: `cp -R examples/ToDo/skills-test <your ToDo app>/skills-test`, register that app in the board, then pick `skills-test/<skill>` in Skill Eval. The copy must be a real folder with no symlinks. A full run of `todo-conventions` costs about $1 at list price.
