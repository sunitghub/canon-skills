# canon: Agent Instructions

Universal instructions for AI coding agents. Loaded natively by Claude Code, Pi, and Codex CLI.

## Approach

- Non-trivial work requires an open ticket before `sprint start`. Trivial fixes (typo, single-line config) are exempt.
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

## Skill Discovery & Registration

The `skills.sh` script lives in `tools/`. After install, `tools/` is on PATH so you can invoke it directly.

To see all available skills:
```bash
skills.sh list
```

To register a skill into the current project:
```bash
skills.sh add <skill-name>
skills.sh add <skill-name> /path/to/project
```

To check what's registered in a project:
```bash
skills.sh status
```

To wire Claude Code hooks after cloning to a new location:
```bash
skills.sh init
```

See [CATALOG.md](CATALOG.md) for a static snapshot of all available skills.

## Testing the Board UI

Any change to `tools/sprint-check-app/app.html` requires Playwright verification — not just grep-based tests.

- Run: `npm run test:ui` (requires sprint-check server on port 8423)
- Start server: `python3 tools/sprint-check-app/server.py`
- Test file: `tests/sprint-check-app.spec.js`
- Ticket card selector: `.card`; create button: `#btn-create`
- `npm test` (bash suite) covers non-UI regressions; both must pass before `sprint complete`

## Worktrees (Parallel Agents)

When running multiple Claude Code instances in parallel worktrees:
- Each worktree uses a long-lived tracking branch (e.g., `claude-code-1/main-1`)
- After a PR merges, reset the tracking branch: `git reset --hard origin/main`
- The worktree keeps its identity across sprints — only the work branch changes

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by `skills.sh` — use `add`/`remove` to change.

| Skill | Category | Source |
|-------|----------|--------|
<!-- AI-SKILLS:END -->
