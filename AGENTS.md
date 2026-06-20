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
- Never end a turn after only stating what you are about to do; if a sentence describes a next action, perform it in the same turn.
- Be concise in output, thorough in reasoning.
- Test before declaring done.

## Standards

See [standards/efficiency.md](standards/efficiency.md) for the full agent standards (code quality, security, git conventions, token efficiency).


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
| sprint | dev | /Users/sunitjoshi/Developer/canon/skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->
