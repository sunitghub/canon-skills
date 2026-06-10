---
name: wrapup
description: Run quality checks, review, and commit after completing a feature, fix, or session — invoke when work is done and ready to ship
category: dev
tags: [code-quality, workflow, orchestration, refactoring, security]
depends: [code-simplifier, code-reviewer, security-review, repo-check, doc-audit, handoff, ticket]
---
@./code-simplifier.md
@./code-reviewer.md
@./security-review.md
@./repo-check.md
@./doc-audit.md
@../tools/handoff.md
@../tools/ticket.md

# Wrapup

Run after a session, feature, bug fix, or ticket. Skip steps that do not apply.

## Pipeline

```
code-simplifier → code-reviewer → security-review → repo-check → doc-audit
```

## Skip Logic

**Trivial change** (single-line, doc-only, mechanical rename): skip all steps except Refresh docs and Commit.

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

### Skip repo-check if:
- No repo workflow, setup, docs, skills, standards, scripts, or tools changed


---

## Steps

1. Apply code-simplifier to code touched in this session.
2. Apply code-reviewer across all seven dimensions; defer deep security analysis to Step 3.
3. Apply security-review, including ast-grep pre-scan if available.
4. Apply repo-check. Fix stale references, orphan workflow files, and generated catalog drift before committing.
5. Apply doc-audit. Do not write to `doc-findings.md` without explicit confirmation. Fix command accuracy issues before committing.
6. Refresh docs:

Review every documentation file touched or referenced during this session and patch anything stale.

Scope (check each that exists):
- `DECISIONS.md` — any new decisions made this session not yet logged?
- `HANDOFF.md` — refresh the narrative per the handoff protocol (`../tools/handoff.md`): Current Focus, In Progress, and Next Steps. `## Discoveries` is owned by capture — leave it. Decisions belong in `DECISIONS.md`, not here.
- `AGENTS.md` / `CLAUDE.md` — any convention-level learnings to surface? (propose + confirm before writing)
- `README` — does it document any changed APIs, behaviors, or install steps?
- Any other `.md` files explicitly opened or modified during the session

Patch stale lines only. Skip files where nothing changed.

---

## Final Output

Report only what matters:

- Changed files and user-visible impact
- Tests run and result
- Critical findings, if any
- Follow-up captured in `HANDOFF.md`, if any

Address criticals before committing. Improvements are discretionary.

If a ticket is in progress, close it with `sprint complete`, not `tkt close`.

---

## Commit & Push

Always run this at the end of every wrapup — even if no code changed (docs and config still need committing).

1. List all modified and untracked files (`git status`). Stage only the files relevant to this session's work — never `git add -A`.
2. Draft a commit message: imperative mood, type prefix, 50-char target. Body if breaking changes or non-obvious reasoning.
3. Show the staged files and commit message. Ask: **"Commit and push? (y to proceed)"**
4. On yes: commit, then push to the current branch's remote. Report the pushed ref.
5. If criticals from the review pipeline are unresolved: warn before asking — do not block, but make the risk explicit.
