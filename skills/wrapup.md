---
name: wrapup
description: Run simplification, review, security review, doc audit, and commit handoff after a unit of work
category: dev
tags: [code-quality, workflow, orchestration, refactoring, security]
depends: [code-simplifier, code-reviewer, security-review, doc-audit, handoff, ticket]
---
@./code-simplifier.md
@./code-reviewer.md
@./security-review.md
@./doc-audit.md
@../tools/handoff.md
@../tools/ticket.md

# Wrapup

Run after a session, feature, bug fix, or ticket. Skip steps that do not apply.

## Pipeline

```
code-simplifier → code-reviewer → security-review → doc-audit
```

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

### Skip doc-audit if:
- No user-facing docs changed (README, guides/, skill descriptions)

---

## Steps

1. Apply code-simplifier to code touched in this session.
2. Apply code-reviewer across all seven dimensions; defer deep security analysis to Step 3.
3. Apply security-review, including ast-grep pre-scan if available.
4. Apply doc-audit. Do not write to `doc-findings.md` without explicit confirmation. Fix command accuracy issues before committing.
5. Refresh docs:

Review every documentation file touched or referenced during this session and patch anything stale.

Scope (check each that exists):
- `DECISIONS.md` — any new decisions made this session not yet logged?
- `HANDOFF.md` — does Next Steps reflect current state?
- `AGENTS.md` / `CLAUDE.md` — any convention-level learnings to surface? (propose + confirm before writing)
- `README` — does it document any changed APIs, behaviors, or install steps?
- Any other `.md` files explicitly opened or modified during the session

Patch stale lines only. Skip files where nothing changed.

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

Address criticals before committing. Improvements and nitpicks are discretionary.

If you ran `/wrapup` directly (not via the approve workflow) and a ticket is in-progress, use the approve workflow to close it — do not call `tkt close` directly.

---

## Commit & Push

Always run this at the end of every wrapup — even if no code changed (docs and config still need committing).

1. List all modified and untracked files (`git status`). Stage only the files relevant to this session's work — never `git add -A`.
2. Draft a commit message: imperative mood, type prefix, 50-char target. Body if breaking changes or non-obvious reasoning.
3. Show the staged files and commit message. Ask: **"Commit and push? (y to proceed)"**
4. On yes: commit, then push to the current branch's remote. Report the pushed ref.
5. If criticals from the review pipeline are unresolved: warn before asking — do not block, but make the risk explicit.
