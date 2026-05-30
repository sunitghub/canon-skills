# 01 - Setup

Start from a project folder. This example already has source and tests, but the same commands apply to a new app.

```bash
cd examples/todo-app
~/Developer/canon/skills.sh add sprint
~/Developer/canon/skills.sh status
```

What this does:

- Adds live canon references to `CLAUDE.md` and `AGENTS.md`.
- Adds the always-on efficiency standard.
- Makes the sprint workflow available to the agent.
- Offers to put `~/Developer/canon/tools` on PATH so `sprint`, `tkt`, and `sprint-check` are available.

If the tools are not on PATH yet:

```bash
export PATH="$PATH:$HOME/Developer/canon/tools"
```
