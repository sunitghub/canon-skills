---
name: efficiency
description: Coding standards, git conventions, and token-efficiency rules for AI agents
category: agent-ops
tags: [coding, security, git, efficiency, tokens]
inject: true
version: 1.0.0
updated: 2026-07-06
---

# Agent Standards

## Code

- Edit existing files, don't create new ones.
- Delete dead code you orphan — no commented blocks, no `_unused` renames. Leave pre-existing dead code unless asked.
- No feature flags or backwards-compat shims — change the code directly.
- No comments unless the WHY is non-obvious.
- Don't reformat, rename, or add type hints to adjacent code — fix only what was asked.
- Out-of-scope issues found while working: `NOTICED: <what>` — don't fix silently.
- Never introduce OWASP Top 10 vulnerabilities or commit secrets, credentials, or `.env` files.
- No new dependencies for problems existing tools solve.
- Test at system boundaries; don't mock what's cheap to integration-test.
- Passing tests verify code correctness, not feature correctness — test both.

## Code Review Feedback

Format: `file:line — <problem>. <fix>.` — no hedging, no preamble, no restating what the code does.
Explain only when the fix isn't self-evident; security/architectural issues get full explanation.
- Ground review in base code, not the PR diff — the diff biases toward the PR's own framing; base code is what actually exists.
- Scope to the change — no frontend notes on backend-only work, no unrelated coverage.

## Git

- Commits: imperative mood, 50-char target / 72-char hard limit, no trailing period.
- Type prefix: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`, `style`, `revert`.
- Focus on WHY — no self-referential language ("This commit...", first-person).
- Prompt changes: log the intent (what failure/behavior it fixes), not just the diff — otherwise regression diagnosis across versions is a day of archaeology.
- Sprint-backed change: `Closes: t-xxxx` in the commit body — the ticket holds the full reasoning, constraints, and acceptance criteria the commit message can only summarize.
- Add a body for breaking changes, non-obvious reasoning, or migration instructions.
- Branches: `feat/short-description`, `fix/short-description`. Never force-push main/master.
- PRs: one concern each, title under 70 chars, body = summary bullets + test plan.
- Never `git add -A` — stage specific files.

## Triggers

Act on these when you see them — don't wait to be told.

- Same fact in multiple files → pick one owner, derive the rest.
- One change needs edits in many unrelated places → fix the missing boundary first.
- Structural edits mixed with behavior changes in one commit → split them.
- Unclear behavior before touching it → characterize current behavior first.
- A third copy of the same logic appears → remove the duplication, don't copy again.
- Tests need excessive setup → the dependency structure is the problem, not the tests.
- Refactor spreading into unrelated areas → cut back to the smallest change that makes the requested edit safe.
- Error surfaces without context → preserve diagnostic info at the boundary, don't swallow it.
- Spec conflicts with existing code → surface it — what each says, the options — and ask; don't silently pick one.
- Non-trivial decision about to be committed → name what you're asserting and what would falsify it before it stands.
- Competitor or adjacent-tool analysis changes how canon should operate → capture it in a skill, standard, guide, or tool behavior before wrapup.
- A workaround, rendering quirk, or undocumented constraint found while fixing → stage it in `HANDOFF.md ## Discoveries` immediately; wrapup routes it to its permanent home (SKILL.md gotcha, `standards/`, DECISIONS.md, or the repo's bug-pattern log if one exists).
- Under `set -euo pipefail`, `VAR=$(cmd)` exits silently if `cmd` fails — `|| fallback` on the next line never runs. Safe: `VAR=$(cmd) || VAR=fallback` on one line.

## Token Efficiency

- Most token spend is re-reading history, not generating output — verbose replies compound across every future turn. Keep it tight.
- Before planning: catalog existing files, patterns, and prior implementations. Name what's reusable before writing new code.
- Read a file before editing it. Grep for callers before modifying a function.
- Reference exact file paths and line numbers — don't re-read files already in context.
- Skip `node_modules`, `.git`, `dist`, `build`, `__pycache__`, `.next` unless asked.
- Use targeted bash commands — avoid ones that dump large output for a narrow query.
- Keep CLAUDE.md and AGENTS.md concise — rules, gotchas, non-obvious conventions only.
- Summarizing or rewriting: preserve code blocks, inline code, paths, URLs, commands, version numbers, and technical terms exactly.
- Run `/context-check` to audit the always-on context budget; log findings to `context-findings.md`.
