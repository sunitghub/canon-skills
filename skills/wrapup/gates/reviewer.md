---
name: code-reviewer
description: Review code touched this session (wrapup's own inline invocation), local changes, or a remote PR across correctness, maintainability, security, and test coverage
category: dev
tags: [code-review, pull-requests, quality]
hidden: true
---

# Code Reviewer

<!-- Not to be confused with skills/sprint/reference/review.md, whose gate name is
     "reviewer" — this file's own gate name is "code-reviewer", despite the
     opposite-looking filenames. See complete.md's Wrapup Gates table. -->

## Scope

- Inline (wrapup's own step 2 invocation): code touched in the current session, from working memory — no git command, no checkout. This is how `wrapup/SKILL.md` runs this gate.
- Local changes (other callers): staged and unstaged diffs
- Remote PR (other callers, e.g. pr-review-style use): PR number or URL; checkout with `gh pr checkout`

## Process

1. Determine target: inline session memory, local diff, or remote PR.
2. For PRs, checkout and read description plus linked tickets.
3. Review all eight dimensions.
4. Report only actionable findings.
5. For PRs, return to the previous/default branch.

## Review Dimensions

Ordered from highest to lowest leverage. Findings at the top of the list must be surfaced before findings at the bottom.

1. **Mental alignment:** does the diff match the approved `plan.md` and `acceptance.md`? Flag scope drift or plan deviation before anything else.
2. **Correct solution:** does it solve the right problem, not just a nearby one?
3. **Design fit:** structure matches local architecture and patterns. Judge against the design principles, tagging violations inline:
   - **SOLID** — single responsibility `[SRP]`, open/closed `[OCP]`, Liskov substitution `[LSP]`, interface segregation `[ISP]`, dependency inversion `[DIP]`.
   - **Coupling & duplication** — don't-repeat-yourself `[DRY]`, Law of Demeter / don't reach through objects `[LoD]`, convention over configuration `[CoC]`.
   - **GoF pattern fit** `[pattern-fit]` — recognize the creational/structural/behavioral families and flag a *clear* misapplied or over-applied pattern (e.g. a Singleton smuggling global state, a needless Factory over a plain constructor), or a genuinely missing pattern that would remove real duplication or coupling. **Default to silence:** never demand a pattern where a simpler construct fits, and don't nag for patterns on procedural/glue code. These design tags weigh most on object-oriented code; on canon's own Bash/Python/Go/markdown surface, prefer the simplest construct — forcing a pattern or abstraction here is itself a `[KISS]`/`[YAGNI]` violation.
4. **Bugs and edge cases:** expected failures and unusual inputs are handled; no off-by-one, null deref, or swallowed errors. For input validation claims, cite the exact guard condition (`file:line`) — finding a pattern (e.g. `.trim()`) elsewhere in the file is not evidence the guard uses it.
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

Explain why each finding matters.
