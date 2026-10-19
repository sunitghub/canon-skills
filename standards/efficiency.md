---
name: efficiency
description: Coding standards, code review feedback, git conventions, behavioral triggers, and token-efficiency rules for AI agents
category: agent-ops
tags: [coding, security, git, efficiency, tokens]
inject: true
version: 1.1.0
updated: 2026-10-15
---

# Agent Standards

## Code

- Prefer editing existing files; add a file only when the task needs one.
- Delete dead code you orphan (no commented blocks, no `_unused`); leave pre-existing dead code unless asked.
- No feature flags or backwards-compat shims: change the code directly.
- Match the surrounding comment density, naming and idiom; comment only where the WHY isn't clear.
- Don't reformat, rename or add type hints to adjacent code.
- Out-of-scope issues: write `NOTICED: <what>`; don't fix silently.
- Never introduce OWASP Top 10 vulnerabilities or commit secrets, credentials or `.env` files.
- No new dependencies for problems existing tools solve.
- Test at system boundaries; don't mock what's cheap to integration-test. Passing tests prove the code, not the feature: test both. Every test names the prod path it protects (owner: `skills/sprint/reference/start-checklist.md` step 6).

## Code Review Feedback

Format: `file:line — <problem>. <fix>.` No hedging, no preamble. A `[severity: … · confidence: …]` tag is calibration, not padding.
Explain only when the fix isn't self-evident; security and architecture findings get a full explanation.
- Ground review in the base code, not the PR diff. Scope to the change.

## Git

- Commits: imperative mood, 50-char target / 72 hard limit, no trailing period; type prefix (`feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`, `style`, `revert`); explain WHY, no "This commit…".
- Sprint-backed change: `Closes: t-xxxx` in the body. Add a body for breaking changes, non-obvious reasoning or migrations.
- Branches `feat/…`, `fix/…`; never force-push main. PRs: one concern, title under 70 chars, body = summary + test plan.
- Never `git add -A`: stage specific files.

## Triggers

Act on these when you see them.

- Same fact in several files → one owner, derive the rest. A third copy of the same logic → remove the duplication.
- One change needs edits in many unrelated places → fix the missing boundary first.
- Structural edits mixed with behavior changes → split the commit.
- Unclear behavior → characterize it before touching it.
- Tests need excessive setup → the dependency structure is the problem.
- Refactor spreading into unrelated areas → cut back to the smallest change that makes the edit safe.
- Error surfaces without context → preserve the diagnostic at the boundary. A failed read, call or command must never look like a normal result.
- Spec conflicts with existing code → surface both and ask; don't pick silently.
- Non-trivial decision about to be committed → name what you assert and what would falsify it.
- A workaround or undocumented constraint found while fixing → note it in `HANDOFF.md ## Discoveries` now; route it to its permanent home before wrapup.
- A guard is verified only by inputs it must reject and by a revert (in a scratch copy) that makes a test fail. A green run in which something did not run proves nothing.
- Never `kill`/`pkill` by name or pattern: kill only a PID you recorded or resolved exactly.
- **Domain rules live in `efficiency-notes.md`, beside this file. Read its section before working in that domain:** editing · duplication exceptions · workarounds found while fixing · shell strict mode and traps · tests, guards and hermetic runs · security checks and gates · destructive commands and user files · renames and doc sweeps · cross-backend parity · Windows / Git Bash · Go · commit messages for prompt changes · the always-on context budget · canon only: competitor analysis.

## Token Efficiency

- Most token spend is re-reading history: keep replies tight.
- Before planning, catalog what exists and name what's reusable. Read a file before editing it; grep for callers (and every reader, sibling, test and fixture) before changing a function or a field's owner.
- Reference `file:line`; don't re-read files already in context. Skip `node_modules`, `.git`, `dist`, `build`, `__pycache__`, `.next`. Use targeted commands, not large dumps.
- When summarizing or rewriting, preserve code blocks, inline code, paths, URLs, commands, versions and technical terms exactly.
