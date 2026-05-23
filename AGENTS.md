# canon: Agent Instructions

Universal instructions for AI coding agents. Loaded natively by Claude Code, Pi, and Codex CLI.

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

See [standards/efficiency.md](standards/efficiency.md) for the full agent standards (code quality, security, git conventions, token efficiency).

Key rules:
- Never introduce security vulnerabilities (OWASP top 10). Never commit secrets.
- Commits: imperative mood, 50/72 chars, type prefix (`feat`, `fix`, `refactor`...), no self-referential language.
- Before editing any file, read it first. Grep callers before modifying a function.
- Don't read `node_modules`, `.git`, `dist`, `build`, `__pycache__`, `.next` unless asked.
- Keep CLAUDE.md and AGENTS.md concise — only rules, gotchas, non-obvious conventions.

## RTK — Token Optimization

RTK (Rust Token Killer) filters verbose CLI output before it hits the token budget.
Claude Code rewrites commands automatically via a `PreToolUse` hook — no action needed.
Codex does not have an equivalent hook: use the `rtk` prefix explicitly.

```bash
rtk git status          # git status
rtk git log --oneline   # git log --oneline
rtk gh api ...          # gh api ...
rtk grep pattern file   # grep pattern file
rtk find . -name "..."  # find . -name "..."
rtk ls -la              # ls -la
rtk read file           # cat file
rtk brew install pkg    # brew install pkg
rtk cargo test          # cargo test
```

When in doubt: `rtk <any-command>`. If RTK has no rule for it, the command passes through unchanged.

## Skill Discovery & Registration

The `skills.sh` script is at the root of this repo. Run it from wherever the repo is cloned.

To see all available skills:
```bash
<path-to-canon>/skills.sh list
```

To register a skill into the current project:
```bash
<path-to-canon>/skills.sh add <skill-name>
<path-to-canon>/skills.sh add <skill-name> /path/to/project
```

To check what's registered in a project:
```bash
<path-to-canon>/skills.sh status
```

To wire Claude Code hooks after cloning to a new location:
```bash
<path-to-canon>/skills.sh init
```

See [CATALOG.md](CATALOG.md) for a static snapshot of all available skills.

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by `skills.sh` — use `add`/`remove` to change.

| Skill | Category | Source |
|-------|----------|--------|
<!-- AI-SKILLS:END -->
