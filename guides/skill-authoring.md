# Skill Authoring Guide

Two tools govern the full lifecycle of a canon skill: `skill-setup-std` (the standard) and `skill-eval` (the quality check). Use them in order.

## The two tools

### 1. skill-setup-std

**Intent:** The rules every skill must follow — file location, frontmatter, description quality, one-job test, progressive disclosure, gotchas. It defines what a valid skill looks like.

**When to use:** Any time you create or edit a skill. Run `./tools/canon-dev.sh lint` after writing to confirm conformance. Re-read the standard when a skill feels bloated or isn't triggering correctly.

### 2. skill-eval

**Intent:** Verifies a skill *behaves correctly* for known prompts. Where skill-setup-std checks structure, skill-eval checks output. It spawns an executor subagent (fresh context, skill content injected) and a grader subagent per test case, then reports pass/fail per expectation.

**When to use:** After writing a new skill, after editing an existing one, or when something feels off about a skill's behavior. Run before registering a skill with `skills.sh add`.

## Order of operations

```
Write SKILL.md
      ↓
canon-dev.sh lint          ← skill-setup-std: structure valid?
      ↓
Write evals/evals.json     ← cover control + at least 2 other case types
      ↓
/skill-eval <name>         ← skill-eval: behavior correct?
      ↓
skills.sh add <name>       ← register for use
```

If lint fails, fix structure before writing evals — a malformed skill may pass evals accidentally.

If eval fails, fix the skill body, not the expectations (unless the expectation itself was wrong).

**Improving an existing skill:** Run evals first to record a baseline pass rate. Make the edit. Re-run. Keep the change only if the pass rate holds or improves — if it regresses, revert and try a narrower edit.

## Coverage checklist

Each eval set should cover at least three of these case types (add `case_type` to each eval for visibility):

| Case type | Question it answers |
|---|---|
| `control` | Does it handle the basic case correctly? |
| `edge` | Does it handle unusual or boundary inputs gracefully? |
| `compliance` | Does it follow its own rules and output format? |
| `boundary` | Does it know when NOT to act (escalate, decline, stop)? |
| `over-caution` | Does it avoid refusing or hedging when it shouldn't? |

See `skills/skill-eval/example.md` for a full annotated walkthrough using the `capture` skill.
