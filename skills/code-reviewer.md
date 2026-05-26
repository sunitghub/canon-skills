---
name: code-reviewer
description: Review local changes or a remote PR across correctness, maintainability, security, and test coverage
category: dev
tags: [code-review, pull-requests, quality]
hidden: true
---

# Code Reviewer

## Scope

- **Local changes** — staged and unstaged diffs in the working tree
- **Remote PR** — by PR number or URL (checkout via `gh pr checkout`)

## Process

1. **Determine target** — is this a remote PR or local changes?
2. **Prepare** — for remote PRs: `gh pr checkout <number>`, gather context (description, linked tickets).
3. **Analyze** across all seven dimensions below.
4. **Report** findings in the structure below.
5. **Cleanup** — for remote PRs: switch back to the default branch when done.

## Seven Dimensions

1. **Correctness** — does the code fulfill its purpose without logical errors?
2. **Maintainability** — is the structure clean, modular, and pattern-consistent?
3. **Readability** — are naming, comments, and formatting clear?
4. **Efficiency** — any performance bottlenecks or unnecessary resource use?
5. **Security** — vulnerabilities or unsafe practices? For destructive actions: server-side auth independent of UI state; single trigger path with consistent guards.
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

Tone: constructive, specific. Explain why, not just what.
