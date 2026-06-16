---
name: skill-eval
description: Runs execution evals for a named skill against test cases in evals/evals.json. Use when you want to verify a skill produces correct output for known prompts, check skill quality after edits, or confirm a new skill works before registering it.
category: dev
tags: [quality, testing, skills, eval]
---

# Skill Eval

Runs execution evals for the skill at `skills/$ARGUMENTS/`.

## What this is not

Trigger eval (whether the skill fires for the right queries) and benchmark/improve/compare modes are **out of scope**. For those, see [skill-creator](https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md).

## Steps

1. **Read the skill.** Read `skills/$ARGUMENTS/SKILL.md` and `skills/$ARGUMENTS/evals/evals.json`. If either is missing, report the gap and stop — a missing `evals.json` is itself a finding.

2. **For each eval case**, run two subagents in sequence:

   **Executor** — spawn an Agent with a clean context. The prompt must:
   - Include the skill's `SKILL.md` content verbatim under a heading "Active skill:"
   - Include the eval `prompt` under "Your task:"
   - Instruct it to execute the task as if it were a fresh session with that skill active
   - Ask it to report: what steps it took, what it would write or output, what tool calls it would make

   **Grader** — spawn a second Agent with a clean context. The prompt must:
   - Include the executor's full response
   - Include the eval `expected_output` and the `expectations` list
   - For each expectation: grade `pass`, `fail`, or `partial` with a one-line evidence citation
   - Return: pass count, total, and per-expectation breakdown

3. **Aggregate.** After all cases complete, output:
   - Per-case: id, prompt summary, verdict, any failed expectations with evidence
   - Overall: `<n>/<total> expectations passed` and `pass` or `fail` verdict

## Output format

```
## Skill Eval: <skill-name>
Run: <ISO date>

### Case <id>: <prompt, truncated to 60 chars>
- "<expectation>" → pass | fail | partial
  Evidence: <one line>

### Summary
<n>/<total> expectations passed
Verdict: pass | fail
```

## Gotchas

- The executor runs in a clean context with only the skill content injected — it has no access to the repo. Expectations like "appended to HANDOFF.md" can only be graded `pass` if the executor explicitly describes taking that action. Grade conservatively; `partial` beats an unsupported `pass`.
- Skills with heavy CLI dependencies (e.g., sprint, which calls `./tools/sprint`) cannot be fully executed in a subagent — the executor will simulate the steps. This is still useful for catching missing steps, wrong output format, or logic errors. Note the limitation in findings when it applies.
- If `evals.json` has no test cases, report it as a finding and stop.
