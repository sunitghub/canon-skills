# Dataflow

Event ingestion and transform pipeline. See `CLAUDE.md` for project instructions.

This fixture is intentionally noisy. It exists to exercise `skills/context-check`
against realistic context setup issues: redundant instructions, vague rules,
dead imports, local skills, MCP server declarations, hooks, and project memory.
All keys, hosts, and paths are fake placeholders.

To use it as an isolated context-check target, run the agent from this directory
with `HOME` pointed at the fixture root. The `.claude/` directory then acts like
a fake Claude home while the project root still exposes `CLAUDE.md`, `AGENTS.md`,
and project-local settings.
