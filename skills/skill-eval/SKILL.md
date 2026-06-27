---
name: skill-eval
description: Runs execution evals for a named skill against test cases in evals/evals.json. Use when you want to verify a skill produces correct output for known prompts, check skill quality after edits, or confirm a new skill works before registering it.
category: dev
tags: [quality, testing, skills, eval]
---

# Skill Eval

Runs execution evals for the skill at `skills/$ARGUMENTS/`.

See [example.md](example.md) for a step-by-step walkthrough using the `capture` skill.

## What this is not

Trigger eval (whether the skill fires for the right queries) and benchmark/improve/compare modes are **out of scope**. For those, see [skill-creator](https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md).

## Steps

0. **Structural check.** Analyse the SKILL.md body (all lines after the closing `---` of the frontmatter) and the eval case count:

   **Registration check (determines body threshold):**
   Run `./tools/skills.sh list 2>/dev/null` and check whether `$ARGUMENTS` appears in the SKILL column.
   - Found → skill is registered and always-on → body threshold is **300 lines**
   - Not found → skill is standalone, a sub-skill, or external → body threshold is **500 lines**

   **Body size:**
   - Count total body lines. If ≤ threshold → output `pass — body within threshold (N lines; threshold: T — always-on)` or `pass — body within threshold (N lines; threshold: T — standalone)` and continue.
   - If > threshold: identify every `##` section and its line span. If 2+ sections each exceed 30 lines → output `candidate for ref/split — body N lines (threshold: T — always-on|standalone); sections <name> (X lines), <name> (Y lines) exceed 30-line threshold`.

   **Eval coverage:**
   - Check whether `skills/$ARGUMENTS/evals/evals.json` exists. This applies to every named target skill, including `skill-eval` itself when running `skill-eval skill-eval`.
   - If missing → output `missing evals — skills/$ARGUMENTS/evals/evals.json not found; fallback creation prompt required`.
   - If present → read it and count the entries in the `evals` array. If count ≥ 3 → output `pass — N eval cases`. If count < 3 → output `too few evals — N case(s); minimum is 3`.

   Output both sub-checks under `### Structural check` in the eval report, before any case results. Both checks are advisory — they do not block execution evals.

   *Thresholds: 300-line body for always-on skills (injected every session); 500-line body for standalone/sub-skill/external (Anthropic hard limit, on-demand only); 30-line section; 3 minimum eval cases.*

1. **Read the skill.** Read `skills/$ARGUMENTS/SKILL.md`. If missing, report the gap and stop.

   Check for `skills/$ARGUMENTS/evals/evals.json`.

   - **If present:** proceed to Step 2 (executor+grader path).
   - **If missing:** run the fallback evaluator (Step 1b) instead of normal eval cases.

1b. **Fallback evaluator (no evals.json).** Spawn a fresh Agent subagent with a clean context. The prompt must:
   - Include the skill's `SKILL.md` content verbatim under "Active skill:"
   - Instruct it to: (a) read the skill and identify 2–3 realistic user scenarios the skill is designed to handle, (b) execute each scenario as if in a fresh session with the skill active — reporting steps taken and output produced, (c) grade whether the skill's instructions were clear and complete enough to guide correct behaviour: `pass`, `partial`, or `fail` with a one-line reason per scenario
   - Ask it to recommend which scenarios should be formalised as `evals.json` cases

   Output fallback results under `### Fallback eval (no evals.json)` in the report, before `### Summary`.

   **Write offer.** After outputting the fallback results, present the recommended scenarios to the user and ask:

   > "Write these as `skills/$ARGUMENTS/evals/evals.json`? (yes/no)"

   - **Yes:** write `skills/$ARGUMENTS/evals/evals.json`. Each recommended scenario becomes one eval case with the fields:
     - `id`: kebab-case slug of the scenario name
     - `case_type`: test technique — `control` (happy path), `compliance` (must-follow rule), `boundary` (edge of valid input), `edge` (unusual but valid), `over-caution` (should not refuse), `self-check` (skill evaluates itself)
     - `prompt`: the scenario as a concrete user-facing prompt string
     - `expected_output`: one sentence describing correct behaviour
     - `expectations`: array of 2–3 specific, assertable strings the grader can verify
     - `type` *(optional)*: `capability` (can it do this new thing?) or `regression` (can it still do the old things?)
     Confirm the file was written, then read the new file and proceed to Step 2.
   - **No:** stop. Do not write anything. Do not proceed to Step 3.

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

3. **Aggregate and report.** After all cases complete:
   - Output the eval report inline (see Output format below).
   - Write the same report to `skills/$ARGUMENTS/skill-eval-result.md`, replacing any prior contents. The file is always written — even if execution evals were skipped due to a missing `evals.json`.

## Output format

```
## Skill Eval: <skill-name>
Run: <ISO date>

### Structural check
Body: pass — body within threshold (N lines; threshold: T — always-on | standalone)
      -or-
      candidate for ref/split — body N lines (threshold: T — always-on | standalone); sections <name> (X lines), <name> (Y lines) exceed 30-line threshold
Evals: pass — N eval cases
       -or-
       too few evals — N case(s); minimum is 3
       -or-
       missing evals — skills/<skill-name>/evals/evals.json not found; fallback creation prompt required

### Case <id>: <prompt, truncated to 60 chars>
- "<expectation>" → pass | fail | partial
  Evidence: <one line>

### Fallback eval (no evals.json)
Scenario <n>: <description>
Verdict: pass | partial | fail — <one-line reason>
...
Recommended evals: <scenario descriptions to formalise as evals.json cases>

### Summary
<n>/<total> expectations passed
Verdict: pass | fail | incomplete (fallback path — no authored evals)

### Issues
| Issue | Details | Reason |
|---|---|---|
| <issue title> | <specific finding> | <why it matters> |
```

Populate the Issues table with any `candidate for ref/split`, `too few evals`, failed expectations, or missing files. Leave the table empty (header only) if no issues were found.

## Gotchas

- The executor runs in a clean context with only the skill content injected — it has no access to the repo. Expectations like "appended to HANDOFF.md" can only be graded `pass` if the executor explicitly describes taking that action. Grade conservatively; `partial` beats an unsupported `pass`.
- Skills with heavy CLI dependencies (e.g., sprint, which calls `./tools/sprint`) cannot be fully executed in a subagent — the executor will simulate the steps. This is still useful for catching missing steps, wrong output format, or logic errors. Note the limitation in findings when it applies.
- If `evals.json` exists but has zero test cases, report it as a finding and stop — the fallback evaluator only fires when the file is entirely absent, not when it exists but is empty.
- Write expectations to assert *outcomes and intent*, not specific phrasing. A grader matching literal wording will false-fail a creative-but-correct executor response. Prefer "executor describes writing the file to the correct path" over "executor outputs the string 'Writing to HANDOFF.md'".
