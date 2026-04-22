---
name: code-reviewer
description: Review local changes or a remote PR across correctness, maintainability, security, and test coverage
category: skills
tags: [code-review, pull-requests, quality]
---

# Code Reviewer

Review local changes or a remote PR with structured analysis across seven dimensions.

## Getting Started

**Step 1 — Register this skill in your project:**
```bash
<path-to-canon>/skills.sh add code-reviewer /path/to/your/project
```

**Step 2 — Verify:**
```bash
<path-to-canon>/skills.sh status /path/to/your/project
```

**Step 3 — Use it:**
- **Review local changes** — Claude or Codex: "Review my changes."
- **Review a remote PR** — "Review PR 42" or paste the PR URL.

The agent determines scope automatically (local diff vs. remote PR), checks out if needed, runs the full analysis, and produces a structured report.

> Tip: Use `wrapup` instead if you want simplify + review + security in one go after finishing a task.

## Scope

- **Local changes** — staged and unstaged diffs in the working tree
- **Remote PR** — by PR number or URL (checkout via `gh pr checkout`)

## Process

1. **Determine target** — is this a remote PR or local changes?
2. **Prepare** — for remote PRs: `gh pr checkout <number>`, verify preflight, gather context (description, linked tickets).
3. **Analyze** across all seven dimensions below.
4. **Report** findings in the structure below.
5. **Cleanup** — for remote PRs: switch back to the default branch when done.

## Seven Dimensions

1. **Correctness** — does the code fulfill its purpose without logical errors?
2. **Maintainability** — is the structure clean, modular, and pattern-consistent?
3. **Readability** — are naming, comments, and formatting clear?
4. **Efficiency** — any performance bottlenecks or unnecessary resource use?
5. **Security** — any vulnerabilities or unsafe practices?
6. **Edge cases** — are errors and unexpected inputs handled?
7. **Test coverage** — are tests adequate? What's missing?

## Report Format

```
## Summary
One paragraph: overall quality and key themes.

## Critical
Issues that must be fixed before merge.

## Improvements
Meaningful changes worth making.

## Nitpicks
Minor style or preference notes (optional to act on).

## Recommendations
Broader suggestions — refactors, missing tests, follow-up work.
```

## Tone

Constructive, professional, and specific. Explain why a change is requested, not just what. Acknowledge good work in approvals.
