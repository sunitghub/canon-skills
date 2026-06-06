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

## Seven Dimensions

1. Correctness: behavior matches intent.
2. Maintainability: structure matches local patterns. Tag SDLC violations inline: `[DRY]` `[SRP]` `[CoC]`.
3. Readability: names, comments, and formatting are clear.
4. Efficiency: no avoidable bottlenecks or waste. Tag: `[KISS]` `[YAGNI]`.
5. Security: no unsafe patterns; destructive actions enforce server-side auth and consistent guards.
6. Edge cases: expected failures and unusual inputs are handled.
7. Test coverage: meaningful risks are tested.

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
