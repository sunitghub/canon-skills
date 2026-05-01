---
name: efficiency
description: Coding standards, git conventions, and token-efficiency rules for AI agents
category: standards
tags: [coding, security, git, efficiency, tokens]
---

# Agent Standards

## Code

- Prefer editing existing files over creating new ones.
- Delete dead code — no commented-out blocks, no `_unused` renames.
- No feature flags or backwards-compat shims when you can change the code directly.
- No comments unless the WHY is non-obvious.
- Never introduce command injection, XSS, SQL injection, or other OWASP top 10 issues.
- Never commit secrets, credentials, or `.env` files.
- Don't add dependencies for problems solvable with existing tools.
- Write tests at system boundaries. Don't mock what you can integration-test cheaply.
- A passing test suite verifies code correctness — not feature correctness. Test both.

## Code Review Feedback

Format: `L<line>: <problem>. <fix>.` — no hedging, no preamble, no restating what the code does.
Include reasoning only when the fix isn't self-evident. Security and architectural issues warrant full explanation.

## Git

- Commits: imperative mood, 50-char target / 72-char hard limit, no trailing period.
- Type prefix: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`, `style`, `revert`.
- Focus on WHY. No self-referential language ("This commit...", first-person pronouns).
- Add body for breaking changes, non-obvious reasoning, or migration instructions.
- Branches: `feat/short-description`, `fix/short-description`. Never force-push main/master.
- PRs: one concern per PR, title under 70 chars, body with summary bullets + test plan.
- Never stage with `git add -A` — pick specific files.

## Token Efficiency

- Before editing any file, read it first. Before modifying a function, grep for callers.
- Reference exact file paths and line numbers — avoid re-reading files already in context.
- Don't read `node_modules`, `.git`, `dist`, `build`, `__pycache__`, `.next` unless asked.
- Use targeted bash commands. Avoid ones that dump large output for a narrow query.
- Keep CLAUDE.md and AGENTS.md concise — only rules, gotchas, non-obvious conventions.
- When summarizing or rewriting content: preserve code blocks, inline code, paths, URLs, commands, version numbers, and technical terms exactly.
