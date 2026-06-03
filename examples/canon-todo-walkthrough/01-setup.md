# 01 - Setup

This folder lives inside the canon source repo, but it is used as its own agent
project root for the walkthrough. In real use you run these commands from your
own project directory; here the walkthrough folder doubles as that project.

`skills.sh add sprint` writes `CLAUDE.md` and `AGENTS.md` to the directory you
run it from. It also ensures a local `.tickets/` folder exists, so `sprint`,
`tkt`, and `sprint-check` treat this folder as the project instead of walking up
to the canon repo root.

```bash
cd examples/canon-todo-walkthrough
../../skills.sh add sprint
../../skills.sh status
```

What this does:

- Adds live canon references to `CLAUDE.md` and `AGENTS.md`.
- Adds the always-on efficiency standard.
- Makes the sprint workflow available to the agent.
- Offers to put the canon `tools` directory on PATH so `sprint`, `tkt`, and
  `sprint-check` are available.

If the tools are not on PATH yet:

```bash
export PATH="$PATH:$(cd ../.. && pwd)/tools"
```

This walkthrough starts without app files. The sprint implementation step will
create `package.json`, `src/`, and `tests/`.
