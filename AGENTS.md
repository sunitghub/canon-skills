# canon: Agent Instructions

Universal instructions for AI coding agents. Loaded natively by Claude Code, Pi, and Codex CLI.

## Approach

- Non-trivial work requires an open ticket before `sprint start`. Trivial fixes (typo, single-line config) are exempt. Any new file, hook/build-script modification, or test-infrastructure change is **normal tier** — eval is mandatory.
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


<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by `skills.sh` — use `add`/`remove` to change.

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | /Users/sunitjoshi/Developer/canon/skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->

## Go MCP server (cmd/mcp-server/)

Experimental Go port of the Python MCP server.

Build: `go build -o mcp-server.exe ./cmd/mcp-server/`
Run: `mcp-server.exe` (stdio MCP protocol)
Test: `go test ./internal/...`

Same 2 core tools as Python: ticket, sprint. (git_info/list_skills dropped — agent can use shell/git directly.)
