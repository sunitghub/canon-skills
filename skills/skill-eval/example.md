# Skill Eval: Step-by-Step Example

Walk-through using the `capture` skill as the subject.

## 1. Create the evals file

```
skills/capture/
  SKILL.md          ← already exists
  evals/
    evals.json      ← create this
```

```json
{
  "skill_name": "capture",
  "evals": [
    {
      "id": 1,
      "case_type": "control",
      "prompt": "Capture: found that sprint start requires tkt binary at tools/tkt, not tools/tkt/tkt",
      "expected_output": "Appended a discovery entry to HANDOFF.md under ## Discoveries and saved a project memory",
      "expectations": [
        "Replied with 'Captured: <summary>'",
        "Would append under ## Discoveries (not ## Current Focus or ## In Progress)",
        "Entry includes date in [YYYY-MM-DD] format",
        "Saved a project memory"
      ]
    },
    {
      "id": 2,
      "case_type": "compliance",
      "prompt": "Capture: the board requires npm run test:ui, not just npm test, because the UI tests need the sprint-check server running",
      "expected_output": "Appended the discovery to HANDOFF.md under ## Discoveries",
      "expectations": [
        "Replied with 'Captured: <summary>'",
        "Appended to ## Discoveries, not another section",
        "Did not invent or add details not present in the prompt"
      ]
    },
    {
      "id": 3,
      "case_type": "over-caution",
      "prompt": "Capture: npm test is slow on first run",
      "expected_output": "Captures the minor observation without hedging or refusing",
      "expectations": [
        "Replied with 'Captured: <summary>'",
        "Did not refuse on grounds that the observation is too minor",
        "Did not ask for clarification before appending"
      ]
    }
  ]
}
```

**What makes a good expectation:**
- Specific and checkable from the executor's output ("appended under ## Discoveries") — not vague ("handled it correctly")
- One thing per expectation — easier to see which part failed
- Covers the failure mode you care about most (wrong section, wrong format, added invented detail)

**What to avoid:**
- "Did the right thing" — unverifiable
- Checking internal tool calls the executor can't observe (e.g., "called the Write tool") — grade against *what was described*, not *how*
- Duplicate expectations that always pass or fail together

## 2. Run the eval

```
/skill-eval capture
```

Expected output:

```
## Skill Eval: capture
Run: 2026-06-16

### Case 1: Capture: found that sprint start requires tkt bi...
- "Replied with 'Captured: <summary>'" → pass
  Evidence: Executor replied "Captured: tkt binary is at tools/tkt"
- "Would append under ## Discoveries (not ## Current Focus...)" → pass
  Evidence: Executor described appending to ## Discoveries section
- "Entry includes date in [YYYY-MM-DD] format" → pass
  Evidence: Entry shown as "- **[2026-06-16]** tkt binary..."
- "Saved a project memory" → pass
  Evidence: Executor described saving a project memory

### Case 2: Capture: the board requires npm run test:ui, not...
- "Replied with 'Captured: <summary>'" → pass
  Evidence: Executor replied "Captured: UI tests require sprint-check server"
- "Appended to ## Discoveries, not another section" → pass
  Evidence: Executor described appending to ## Discoveries
- "Did not invent or add details not present in the prompt" → pass
  Evidence: Executor output matches prompt content; no extra claims

### Summary
7/7 expectations passed
Verdict: pass
```

## 3. When a case fails

Example: grader returns `fail` on expectation 3 of case 1:

```
- "Entry includes date in [YYYY-MM-DD] format" → fail
  Evidence: Executor described appending "- tkt binary is at tools/tkt" with no date
```

Fix the skill (in this case, `capture/SKILL.md` might be missing explicit date format instruction), re-run `/skill-eval capture`, confirm the expectation now passes.

## Notes

- The executor runs with **only the skill content injected** — no repo access. Expectations that require reading files (e.g., "HANDOFF.md was updated") are graded on whether the executor *described* taking that action, not whether the file actually changed. This is a simulation, not a live run.
- For skills with CLI dependencies (e.g., `sprint` calls `./tools/sprint`), the executor will describe what it *would* do. Still useful for catching wrong steps, wrong output format, or missing behavior.
- Add evals when you change a skill — run before and after to confirm behavior didn't regress.
- **Grader calibration:** On first run, spot-check whether the grader's verdicts match your own read of the executor output. If they diverge, the expectations are usually too vague — tighten them before trusting the pass rate. The grader is uncalibrated by default; your judgment is the ground truth until the evals prove otherwise.
