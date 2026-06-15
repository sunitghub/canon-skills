---
name: code-reviewer
description: Review local changes or a remote PR across correctness, maintainability, security, and test coverage
category: dev
tags: [code-review, pull-requests, quality]
hidden: true
---

# Code Reviewer

## Scope

- Local changes: staged and unstaged diffs
- Remote PR: PR number or URL; checkout with `gh pr checkout`

## Process

1. Determine target: local diff or remote PR.
2. For PRs, checkout and read description plus linked tickets.
3. Review all seven dimensions.
4. Report only actionable findings.
5. For PRs, return to the previous/default branch.

## Review Dimensions

Ordered from highest to lowest leverage. Findings at the top of the list must be surfaced before findings at the bottom.

1. **Mental alignment:** does the diff match the approved `plan.md` and `acceptance.md`? Flag scope drift or plan deviation before anything else.
2. **Correct solution:** does it solve the right problem, not just a nearby one?
3. **Design fit:** structure matches local architecture and patterns. Tag violations inline: `[DRY]` `[SRP]` `[CoC]`.
4. **Bugs and edge cases:** expected failures and unusual inputs are handled; no off-by-one, null deref, or swallowed errors.
5. **Test coverage:** meaningful risks are tested; tests exercise behavior, not implementation details.
6. **Security:** no unsafe patterns; destructive actions enforce server-side auth and consistent guards.
7. **Efficiency:** no avoidable bottlenecks or waste. Tag: `[KISS]` `[YAGNI]`.
8. **Style and readability:** names, comments, and formatting are clear — flag only when it affects future maintenance.

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

Be specific. Explain why each finding matters.
