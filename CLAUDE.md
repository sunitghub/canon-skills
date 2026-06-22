# canon: Project-Local Instructions

Canon-specific guidance that applies only in this repo. Global instructions are in `~/.claude/CLAUDE.md`.

## Agent Design

- One skill, one job. A skill that does two things is two skills waiting to be separated.
- Compose agents from tools + context + prompts — not inheritance hierarchies.
- Request only the tools the current task needs. Bloated tool schemas degrade reasoning.
- Prefer reversible actions. Confirm before irreversible ones (send, delete, publish, deploy).
- Fail loudly — surface ambiguity rather than guessing silently.
- Solve with one agent before building a multi-agent pipeline. Complexity compounds failure.
- Requirements define intent; code defines reality. The gap between them is where hallucination lives.

## Worktrees (Parallel Agents)

When running multiple Claude Code instances in parallel worktrees:
- Each worktree uses a long-lived tracking branch (e.g., `claude-code-1/main-1`)
- After a PR merges, reset the tracking branch: `git reset --hard origin/main`
- The worktree keeps its identity across sprints — only the work branch changes
