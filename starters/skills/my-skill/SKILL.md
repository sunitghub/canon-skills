---
name: my-skill
description: One sentence — what this skill does and when to invoke it. Shown in skill lists and used by the harness to decide relevance.
category: dev
tags: [keyword, keyword]
# Visibility options (pick one if needed, omit for default standalone):
#   hidden: true                    — internal sub-skill, never user-invoked
#   user-invocable: false           — hidden from / menu; Claude can still load it
#   disable-model-invocation: true  — user-invokable only; Claude won't auto-load
---

# My Skill

One-line summary.

## Trigger

When this skill fires: describe the user input pattern or condition that activates it.
Examples: "When the user asks to X", "After Y completes", "When file Z is mentioned."

## Steps

1. **Step one.** Be specific. Reference actual files: "Read `tools/ticket.md`, then run `tkt create`."
2. **Step two.** What to do after step one.
3. **Output.** What to produce: write to a file, print to console, return a structured result.

## Output Format

```
## Result: <name>

- Finding one
- Finding two

Verdict: pass | fail | needs-review
```

## Gotchas

- Non-obvious constraint the agent won't infer from the steps.
- Edge case that produces wrong output if not handled explicitly.
