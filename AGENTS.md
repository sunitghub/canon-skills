# AI-Skills: Agent Instructions

Universal instructions for AI coding agents. Loaded natively by Pi and Codex CLI.
Claude Code loads this via `adapters/claude/CLAUDE.md`.

## Approach

- Think before coding. Surface tradeoffs, don't hide confusion.
- Minimum code that solves the problem. Nothing speculative.
- Touch only what you must. Clean up only your own mess.
- Define success criteria before starting. Verify when done.
- Read existing files before writing code.
- If multiple interpretations exist, present them — don't pick silently.
- Be concise in output, thorough in reasoning.
- Test before declaring done.

## Code Quality

- No comments unless the WHY is non-obvious (hidden constraint, subtle invariant, workaround).
- No error handling for scenarios that can't happen. Trust internal guarantees.
- Only validate at system boundaries (user input, external APIs).
- No speculative abstractions. Three similar lines beats a premature helper.
- No half-finished implementations.
- No backwards-compatibility shims for removed code.

## Output Style

- No sycophantic openers or closing fluff.
- Short responses by default. Expand only when the task requires it.
- Reference code as `file_path:line_number` when applicable.
- No emoji unless explicitly requested.

## Standards

See [standards/general.md](standards/general.md) for coding conventions.
See [standards/git.md](standards/git.md) for git and commit conventions.
