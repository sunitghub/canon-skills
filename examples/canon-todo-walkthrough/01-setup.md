# 01 - Setup

**What this step does:** Tells canon that this folder is a project, and puts the
sprint tools on your PATH so the `sprint`, `tkt`, and `sprint-check` commands
are available. You only do this once per project.

This folder lives inside the canon source repo, but it acts as its own project
root for the walkthrough. In real use you run these commands from your own
project directory.

```bash
cd examples/canon-todo-walkthrough
../../skills.sh add sprint
../../skills.sh status
```

Concretely, this:

- Creates a local `.tickets/` folder — where tickets, acceptance criteria, and
  sprint plans are stored on disk.
- Writes `CLAUDE.md` and `AGENTS.md` so the agent knows the sprint workflow.
- Offers to put the canon `tools` directory on PATH so `sprint`, `tkt`, and
  `sprint-check` are available as commands.

The first `sprint start` will also create `HANDOFF.md` and `DECISIONS.md` if
they do not exist. That is canon's session-continuity layer: a new agent reads
the same local context instead of asking you to reconstruct the sprint from
memory.

If the tools are not on PATH yet:

```bash
export PATH="$PATH:$(cd ../.. && pwd)/tools"
```

This walkthrough starts without app files. The implementation step later will
create `package.json`, `src/`, and `tests/`.

> **For product managers:** You don't need to run any of these commands. Ask
> your developer to complete this step, then open the board with `sprint-check`
> from the project folder. Everything else in the walkthrough is visible there.
