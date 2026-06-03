# canon

<div align="center">

### Plan. Build. See it.

Two commands and a local board. Your agent forgets — your repo shouldn't.

[![npm](https://img.shields.io/npm/v/canon-skills?color=3b82f6&label=npm)](https://www.npmjs.com/package/canon-skills)
[![license](https://img.shields.io/badge/license-MIT-2563eb)](LICENSE)
![local-first](https://img.shields.io/badge/state-local--first-22c55e)
![no-saas](https://img.shields.io/badge/SaaS-none-64748b)

</div>

![sprint-check board — drag a ticket to Done, open it, follow the commit links](meta/board-demo.gif)

```bash
npx canon-skills@latest          # installs canon to ~/Developer/canon
cd /path/to/your-project
~/Developer/canon/skills.sh add sprint
```

Then build with two commands and a board:

```bash
sprint start "add OAuth login"   # plan the work, create a local ticket
sprint-check                     # open the board in your browser
sprint complete                  # review, verify, close
```

That's the whole surface. Your agent does the work; canon keeps it in your repo — not your prompt history.

## The Board

`sprint-check` reads your `.tickets/` folder, `HANDOFF.md`, and `git log`, and opens a local kanban board in your browser. No account, no remote, no commit — the work is already there. It shows git state, current focus, recent commits, ticket status, and sprint docs at a glance, and tickets link to commits automatically.

Where phase-based frameworks like GSD Core give you a multi-command methodology to learn, canon gives you two commands and a board you can see.

**[Full feature tour →](docs/sprint-check.md)** — dark mode, ticket detail, in-place doc editing, commit intelligence, drag-to-update, completeness checks.

## The Two Commands

- **`sprint start "<what>"`** — creates a local ticket, then has your agent define acceptance, map the codebase, surface gray areas, rate risk, and write a plan before touching source. The plan lives in `.tickets/<id>/` and survives context resets.
- **`sprint complete`** — runs the close path: simplify → review → security → repo/doc audit → acceptance check → close → commit & push prompt.

A ticket is a folder, not a card — ticket, acceptance, plan, and decisions, all markdown in your repo. When context resets mid-session, the agent reopens the folder and picks up where it left off.

**Gated, not vibes.** The CLI owns state: one active sprint at a time, and `sprint complete` refuses to close while any acceptance item is still unchecked. The agent owns judgment — the gate owns the close.

## How Sprint Works

`sprint start` plans before it builds:

```mermaid
flowchart LR
    S1[Ticket] --> S2[Acceptance] --> S3[Blueprint] --> S4[[orient]]
    S4 --> S5[Grill] --> S6[[impact]] --> S7[Approval] --> S8[Plan]
    classDef subskill stroke:#8888dd,stroke-width:2px
    class S4,S6 subskill
```

`sprint complete` gates the close:

```mermaid
flowchart LR
    W1[[simplifier]] --> W2[[reviewer]] --> W3[[security]] --> W4[[repo-check]] --> W5[[doc-audit]] --> C6[close]
    classDef subskill stroke:#8888dd,stroke-width:2px
    class W1,W2,W3,W4,W5 subskill
```

Double-bordered nodes are sub-skills the agent runs inside the flow — you don't invoke them. **[Full lifecycle →](docs/sprint-check.md#how-sprint-works)**

## Why

Define your standards once; every project inherits them via `@`-import — Claude Code, Codex, and Pi, in sync. Update the canon repo, every project picks it up on the next session. No copies, no drift, no setup ritual per project. The `efficiency` standard is wired automatically when you register `sprint`.

## Setup

| Tool | Required | For |
|---|---|---|
| Claude Code / Codex / Pi | At least one | running the agent |
| Node.js ≥ 16 | `npx` install only | install |
| Python 3 | `sprint-check` + hooks | the board |

```bash
~/Developer/canon/skills.sh add sprint          # plan → build → ship (includes wrapup, handoff)
~/Developer/canon/skills.sh add context-check   # optional: context-budget audits
```

- **[Full setup guide →](guides/AI-Agents-Setup.md)** — per-agent wiring, the live-reference model, verification.
- **[Todo walkthrough →](examples/canon-todo-walkthrough)** — the full flow end to end, from empty board to shipped app.

---

> canon /ˈkænən/ — the standard your agent follows across projects.

*Make it canon.*
