---
name: efficiency
description: Coding standards, git conventions, and token-efficiency rules for AI agents
category: agent-ops
tags: [coding, security, git, efficiency, tokens]
---

# Agent Standards

## Code

- Prefer editing existing files over creating new ones.
- Delete dead code your changes made unused — no commented-out blocks, no `_unused` renames. Don't touch pre-existing dead code unless asked.
- No feature flags or backwards-compat shims when you can change the code directly.
- No comments unless the WHY is non-obvious.
- Don't reformat, rename, or add type hints to adjacent code — fix only what was asked.
- Never introduce OWASP top 10 vulnerabilities. Never commit secrets, credentials, or `.env` files.
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

## Agent Design

- One skill, one job. A skill that does two things is two skills waiting to be separated.
- Compose agents from tools + context + prompts — not inheritance hierarchies.
- Request only the tools the current task needs. Bloated tool schemas degrade reasoning.
- Prefer reversible actions. Confirm before irreversible ones (send, delete, publish, deploy).
- Fail loudly — surface ambiguity rather than guessing silently.
- Solve with one agent before building a multi-agent pipeline. Complexity compounds failure.

## Token Efficiency

- 98%+ of token spend is re-reading prior conversation history, not generating responses. Every verbose output compounds across all future turns — keep it tight.
- Before editing any file, read it first. Before modifying a function, grep for callers.
- Reference exact file paths and line numbers — avoid re-reading files already in context.
- Don't read `node_modules`, `.git`, `dist`, `build`, `__pycache__`, `.next` unless asked.
- Use targeted bash commands — avoid ones that dump large output for a narrow query.
- Keep CLAUDE.md and AGENTS.md concise — only rules, gotchas, non-obvious conventions.
- When summarizing or rewriting content: preserve code blocks, inline code, paths, URLs, commands, version numbers, and technical terms exactly.
- Run `/context-check` to audit the always-on context budget and log new findings to `standards/context-findings.md`.
