# canon: Agent Instructions

Universal instructions for AI coding agents. Loaded natively by Claude Code, Pi, and Codex CLI.

## Approach

- Non-trivial work requires an open ticket before `sprint start`. Trivial fixes (typo, single-line config) are exempt.
- Think before coding. Surface tradeoffs, don't hide confusion.
- Minimum code that solves the problem. Nothing speculative.
- Touch only what you must. Clean up only your own mess.
- Define success criteria before starting. Verify when done.
- If multiple interpretations exist, present them — don't pick silently.
- Never end a turn after only stating what you are about to do; if a sentence describes a next action, perform it in the same turn.
- Be concise in output, thorough in reasoning.
- Test before declaring done.

## Standards

See `standards/efficiency.md` for the full agent standards (code quality, security, git conventions, token efficiency).

## Canon MCP Tools

This project has a canon MCP server exposing sprint management tools. Use these instead of CLI commands or manual file edits:

- `get_sprint_board()` — view all tickets + handoff context
- `get_ticket(ticket_id)` — read ticket files (plan.md, acceptance.md, etc.)
- `start_sprint(title=...)` — create ticket + plan.md, ensure DECISIONS.md/HANDOFF.md
- `close_sprint()` — validate gates, generate receipt, update HANDOFF.md
- `create_sprint_ticket(description, priority)` — add a new sprint ticket
- `update_ticket_status(ticket_id, new_status)` — change ticket status
- `add_acceptance_criterion(ticket_id, criterion)` — add acceptance criteria
- `list_skills(skill_name=...)` — discover installed skills under `skills/`
- `open_dashboard()` — launch kanban web UI

`list_skills()` is the canonical way to find useful skills. It reads `skills/` directory metadata.

## Submodule Usage

When canon-skills is a git submodule inside a parent project, run from the parent root:

```bash
bash canon-skills/scripts/submodule-setup.sh
```

This wires canon's MCP server, agent hooks, and instructions into the parent project's config files. See `scripts/submodule-setup.sh` for details.

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by `skills.sh` — use `add`/`remove` to change.

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->
