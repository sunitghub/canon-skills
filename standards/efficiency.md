---
name: efficiency
description: Coding standards, git conventions, and token-efficiency rules for AI agents
category: agent-ops
tags: [coding, security, git, efficiency, tokens]
inject: true
version: 1.0.0
updated: 2026-06-03
---

# Agent Standards

## Code

- Prefer editing existing files over creating new ones.
- Delete dead code your changes made unused — no commented-out blocks, no `_unused` renames. Don't touch pre-existing dead code unless asked.
- No feature flags or backwards-compat shims when you can change the code directly.
- No comments unless the WHY is non-obvious.
- Don't reformat, rename, or add type hints to adjacent code — fix only what was asked.
- Out-of-scope issues noticed while working: surface as `NOTICED: <what>`, don't fix silently.
- Never introduce OWASP top 10 vulnerabilities. Never commit secrets, credentials, or `.env` files.
- Don't add dependencies for problems solvable with existing tools.
- Write tests at system boundaries. Don't mock what you can integration-test cheaply.
- A passing test suite verifies code correctness — not feature correctness. Test both.

## Code Review Feedback

Format: `L<line>: <problem>. <fix>.` — no hedging, no preamble, no restating what the code does.
Include reasoning only when the fix isn't self-evident. Security and architectural issues warrant full explanation.
- Ground review in base code, not the PR diff. The diff biases toward the PR's own framing; the base code is what actually exists.
- Scope review to areas relevant to the change. No frontend comments on backend-only features, no unrelated surface coverage.

## Git

- Commits: imperative mood, 50-char target / 72-char hard limit, no trailing period.
- Type prefix: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`, `style`, `revert`.
- Focus on WHY. No self-referential language ("This commit...", first-person pronouns).
- For prompt changes: log the intent — what failure or behaviour the prompt was meant to fix — not just what changed. Version tracking without intent makes regression diagnosis across multiple versions a day of archaeology.
- For any sprint-backed change: include the ticket ID in the commit body (`Closes: t-xxxx`). The ticket holds the full reasoning, constraints, and acceptance criteria that the commit message can only summarise.
- Add body for breaking changes, non-obvious reasoning, or migration instructions.
- Branches: `feat/short-description`, `fix/short-description`. Never force-push main/master.
- PRs: one concern per PR, title under 70 chars, body with summary bullets + test plan.
- Never stage with `git add -A` — pick specific files.

## Triggers

Act on these when you see them — don't wait to be told.

- Same fact in multiple files → pick one owner, derive the rest.
- One change requires edits in many unrelated places → fix the missing boundary first.
- Mixing structural edits with behavior changes in one commit → split them.
- Unclear behavior before touching it → characterize what it does now before changing anything.
- A third copy of the same logic appears → remove the duplication; don't copy again.
- Tests require excessive setup to run → the dependency structure is the problem, not the tests.
- Refactor spreading into unrelated areas → cut back to the smallest change that makes the requested edit safe.
- Error surfaces without context → preserve the diagnostic information at the boundary, don't swallow it.
- Spec conflicts with existing code → surface it: what each says, the options, and ask — don't silently pick one.
- Non-trivial decision about to be committed → name what you're asserting and what would falsify it before it stands.
- Competitor or adjacent-tool analysis changes how canon should operate → capture it in a skill, standard, guide, or tool behavior before wrapup.
- A workaround, rendering quirk, or undocumented constraint discovered while fixing → stage it in `HANDOFF.md ## Discoveries` immediately; wrapup routes it to its permanent home (SKILL.md gotcha, `standards/`, DECISIONS.md, or the repo's bug-pattern log if one exists).

## Token Efficiency

- 98%+ of token spend is re-reading prior conversation history, not generating responses. Every verbose output compounds across all future turns — keep it tight.
- Before proposing a plan, catalog what already exists: related files, similar patterns, prior implementations. Name what's reusable before writing new code.
- Before editing any file, read it first. Before modifying a function, grep for callers.
- Reference exact file paths and line numbers — avoid re-reading files already in context.
- Don't read `node_modules`, `.git`, `dist`, `build`, `__pycache__`, `.next` unless asked.
- Use targeted bash commands — avoid ones that dump large output for a narrow query.
- Keep CLAUDE.md and AGENTS.md concise — only rules, gotchas, non-obvious conventions.
- When summarizing or rewriting content: preserve code blocks, inline code, paths, URLs, commands, version numbers, and technical terms exactly.
- Run `/context-check` to audit the always-on context budget and log new findings to `context-findings.md`.
