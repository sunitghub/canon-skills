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
4. Report every real finding — place each into the severity sections below rather than omitting it; do not drop a finding because it looks low-severity or you are not fully certain. Coverage is the job at the finding stage; ranking and filtering happen in the sections (and downstream, via the human).
5. For PRs, return to the previous/default branch.

## Review Dimensions

Ordered from highest to lowest leverage. Findings at the top of the list must be surfaced before findings at the bottom.

1. **Mental alignment:** does the diff match the approved `plan.md` and `acceptance.md`? Flag scope drift or plan deviation before anything else.
2. **Correct solution:** does it solve the right problem, not just a nearby one?
3. **Design fit:** structure matches local architecture and patterns. Tag violations inline:
   - **SOLID** — `[SRP]` single responsibility, `[OCP]` open/closed, `[LSP]` Liskov substitution, `[ISP]` interface segregation, `[DIP]` dependency inversion.
   - **Coupling & duplication** — `[DRY]` don't-repeat-yourself, `[LoD]` Law of Demeter (don't reach through objects), `[CoC]` convention over configuration.
   - **GoF pattern fit** `[pattern-fit]` — flag a *clear* misapplied/over-applied pattern (a Singleton smuggling global state, a needless Factory over a plain constructor) or a missing one that would remove real duplication/coupling. **Default to silence:** never demand a pattern where a simpler construct fits; don't nag on procedural/glue code. These tags weigh most on OO code; on canon's Bash/Python/Go/markdown surface, forcing a pattern or abstraction is over-engineering — flag it under Efficiency (dim. 7), which owns `[KISS]`/`[YAGNI]`.
4. **Bugs and edge cases:** expected failures and unusual inputs are handled; no off-by-one, null deref, or swallowed errors. For input validation claims, cite the exact guard condition (`file:line`) — finding a pattern (e.g. `.trim()`) elsewhere in the file is not evidence the guard uses it.
5. **Test coverage:** meaningful risks are tested; tests exercise behavior, not implementation details.
6. **Security (shallow):** no obviously unsafe patterns; destructive actions enforce server-side auth and consistent guards. This is a *shallow* pass — deep/exploit-level analysis is deferred to `security-review` (close step 3); don't duplicate it here.
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

Report for coverage, then rank. A genuine correctness, bug, or scope finding belongs in `Critical` or `Improvements` even at low confidence — mark it `(low confidence)` rather than omitting it; the section is the severity ranking and the human is the downstream filter, so a finding that later gets filtered out is cheaper than a missed defect. `Nitpicks` is for subjective style/preference notes only, and is the one bucket where the design-fit `[pattern-fit]` "default to silence" rule (dim. 3) still governs — keep it sparse; coverage never means style nagging. Explain why a finding matters only when the fix isn't self-evident; security and architectural findings always get a full explanation (per `standards/efficiency.md`). This PR-style report format is intentionally distinct from the sprint `reviewer` gate's terse one-finding-per-line format (`skills/sprint/reference/review.md`).
