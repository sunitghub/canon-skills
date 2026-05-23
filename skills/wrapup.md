---
name: wrapup
description: Run code-simplifier, code-reviewer, and security-review in the right order after completing any unit of work — skips steps that don't apply
category: dev
tags: [code-quality, workflow, orchestration, refactoring, security]
depends: [code-simplifier, code-reviewer, security-review, handoff, ticket]
---
@./code-simplifier.md
@./code-reviewer.md
@./security-review.md
@../tools/handoff.md
@../tools/ticket.md

# Wrapup — Quality Pipeline

Run this after completing any unit of work — a session, a feature, a bug fix, or a ticket. It executes three steps in sequence, skipping any that don't apply to the current change.

## How to Run

```
/wrapup
```

Or: "Wrapup the changes" / "Wrapup the auth refactor" / "Wrapup ticket proj-42."

## Pipeline

```
code-simplifier → code-reviewer → security-review
```

Each step builds on the last:
- **Simplify first** — review clean code, not messy code
- **Review second** — catch logic and design issues on the simplified version
- **Security last** — focused pass with no style noise in the way

## Skip Logic

Before running each step, assess the change and skip if the criteria apply. When skipping, state why in one line.

### Skip code-simplifier if:
- Change is a single line or a trivial rename
- Change is docs, comments, or config only

### Skip code-reviewer if:
- Change is a single-line fix with no design implications
- Change is purely mechanical (rename, format, move file)

### Skip security-review if:
- No security-sensitive files or patterns changed
- Security-sensitive means: authentication, authorization, DB queries, user input handling, file I/O, API endpoints, crypto, session management, environment/secret access

---

## Step 1 — Code Simplifier

Apply the code-simplifier skill. Scope: only code touched in the current session unless explicitly asked otherwise.

## Step 2 — Code Reviewer

Apply the code-reviewer skill across all seven dimensions. For security: note concerns but defer deep analysis to Step 3.

## Step 3 — Security Review

Apply the security-review skill, including the ast-grep pre-scan.

---

## Final Output

```
## Wrapup Report — <description of work>

### Changes
| File | What changed | Impact | Flags |
|------|-------------|--------|-------|
| path/to/file.ext | one-line description | HIGH / MEDIUM / LOW | ✓ clean / ⚠ see below |

### code-simplifier
- <what was simplified and where>

### code-reviewer
- [Critical] ...
- [Improvement] ...

### security-review
- [High] ...
```

**Changes table columns:**
- **File** — relative path
- **What changed** — one line: what the code now does differently
- **Impact** — carry forward the rating from `blueprint.md ## Impact Assessment`; use LOW if no sprint context
- **Flags** — `✓ clean` if no findings; `⚠ critical` / `⚠ improvement` if the pipeline flagged anything for that file

Address criticals before committing. Improvements and nitpicks at your discretion.

If you ran `/wrapup` directly (not via the approve workflow) and a ticket is in-progress, use the approve workflow to close it — do not call `tkt close` directly.

