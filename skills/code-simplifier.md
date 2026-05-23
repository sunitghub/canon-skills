---
name: code-simplifier
description: Simplify and refine recently modified code for clarity, consistency, and maintainability without changing behavior
category: skills
tags: [refactoring, code-quality, cleanup]
hidden: true
---

# Code Simplifier

**Preserve functionality** — never change what the code does, only how it does it.

**Apply project standards** — follow conventions in CLAUDE.md / AGENTS.md.

**Enhance clarity:**
- Reduce unnecessary nesting and complexity
- Eliminate redundant code and abstractions
- Improve variable and function names
- Consolidate related logic
- Remove comments that describe obvious code
- No nested ternaries — use `if/else` or `switch` instead
- Explicit over compact — a clear longer line beats a dense one-liner

**Do not:**
- Sacrifice readability for brevity or cleverness
- Merge unrelated concerns into one function
- Remove abstractions that genuinely aid organization

**Scope** — only refine code touched in the current session unless explicitly asked to do more.

## Process

1. Identify recently modified sections.
2. Apply project standards; verify behavior is unchanged.
3. Note only changes that meaningfully affect understanding.
