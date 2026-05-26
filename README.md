# canon

The average person can hold about four items in active working memory. Most agent sessions need more than that before you write a line of code.

*canon /ˈkænən/ — an established rule or principle; the authoritative standard a team agrees to follow.*

> Your agents are capable. Canon makes them yours.

Stop re-explaining your standards on every new project. Stop watching Claude drift back to its defaults mid-session. Stop reconfiguring the same quality checks from scratch. Stop piecing together what's in flight from git log and open tabs.

canon is a shared skill library for AI coding agents. Define your standards once. Every project inherits them automatically — Claude Code, Codex, and Pi, all in sync.

```bash
# Install
npx canon-skills@latest

# Register skills in a project
~/Developer/canon/skills.sh add sprint
```

Skills are live references, not copies. `skills.sh add sprint` writes one line to your project's CLAUDE.md:

```
@~/Developer/canon/skills/sprint.md
```

Claude Code resolves it at session start, reading directly from canon. Update canon — every project picks it up on the next `git pull`.

Two commands cover the full lifecycle:

| | |
|---|---|
| `sprint start` | Maps the codebase, surfaces ambiguities, rates risk, writes a plan — waits for your approval before touching any code. |
| `sprint complete` | Quality pipeline, doc refresh, ticket close, commit & push prompt. Done. |

Everything else — tickets, session context, quality gates, handoff across resets — runs automatically. You don't learn a vocabulary. You describe what you want to build.

---

## Why canon

Most agent repos I tried gave me homework. A vocabulary of slash commands to memorize. An invocation order that wasn't written down anywhere. A setup ritual to repeat on every new project. The overhead of operating the framework started eating into the time I'd saved by using an agent.

I wanted the opposite: define my standards once, have every agent read them automatically, and never think about configuration again. Open a session — your agent already knows how you work, what's in progress, and what decisions were made last week.

The second problem was visibility. As a solo builder, when I'm deep in a session and need to know what's in flight, I don't want to push commits to GitHub just to see a diff, spin up a Jira board, or maintain a project in three browser tabs that requires a remote repo to even exist. I just want to see my work — right now, in the repo, without ceremony.

That's sprint-check: a kanban board that reads your `.tickets/` folder and `git log` directly, opens in a browser tab, and requires nothing else — no account, no remote, no commit. The same instinct behind canon: the best tool for a developer is one that disappears.

If you're on a team, the problems compound. Each engineer maintains their own agent config, each drifting in a different direction. Onboarding a new teammate means handing them a setup guide that's already out of date. When someone discovers a better pattern mid-sprint, it stays in their head or a Slack thread — not in every future session. Canon gives teams a shared source of truth: fork it to your org, have everyone clone from there, and there's one place where what the team has learned actually lives. One engineer pushes an update — every teammate picks it up on the next `git pull`. No config drift, no stale copies, no setup guide that's already out of date by the time someone reads it.

---

## Why not just paste instructions into CLAUDE.md?

You can. Most people do — until they have five projects, each with a slightly different copy, all drifting apart. Canon solves this with a **live-reference model**: skills live in one repo and are `@`-imported directly into each project's config. Update once, every project picks it up on the next session start. No copies. No drift. No tribal knowledge trapped in one engineer's config.

---

## What's inside

In practice you need two commands. The rest is wired in automatically.

| Skill | What it does |
|---|---|
| `sprint` | plan → build → ship. Creates a ticket automatically on start, closes it on complete — no manual ticketing. Maps the subsystem, grills gray areas, rates impact, generates a test plan. Approved plan written to `.tickets/<id>/plan.md` (or `planning/sprints/<slug>/plan.md` without tkt) — survives context resets. |
| &nbsp;&nbsp;↳ `wrapup` | Quality pipeline at sprint complete (also runs on demand): simplify → review → security → doc refresh, then always prompts to commit & push. |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `code-reviewer` | Structured review across 7 dimensions: correctness, maintainability, readability, efficiency, security, edge cases, and test coverage. |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `security-review` | High-confidence vulnerability detection — traces data flow before flagging anything. |
| &nbsp;&nbsp;↳ `handoff` | Session context that survives agent switches, resets, and context window exhaustion. |
| `efficiency` | Token-efficiency rules for AI agents. Opinionated but battle-tested. |
| `context-check` | Audit the always-on context budget — imports, active skills, hooks, memory. Appends findings to `standards/context-findings.md` on explicit confirmation. |
| `doc-audit` | Audit user-facing docs for overstated claims, missing prerequisites, and scope inflation. Appends findings to `standards/doc-findings.md` on explicit confirmation. |
| `sprint-check` | Local kanban dashboard. Reads `.tickets/`, `HANDOFF.md`, and `git log`. Runs in any browser. |

---

## How sprint works

Two commands drive the full lifecycle. Sub-skills are called in automatically at each stage — no manual orchestration.

### sprint start

```mermaid
flowchart LR
    S1[Ticket] --> S4[[orient]] --> S5[Grill] --> S6[[impact]] --> S9[plan]
    classDef subskill stroke:#8888dd,stroke-width:2px
    class S4,S6 subskill
```

### ↓ Build

> `capture` fires automatically — discoveries saved to `HANDOFF.md`

### sprint complete

```mermaid
flowchart LR
    W1[[simplifier]] --> W2[[reviewer]] --> W3[[security]] --> W4[[doc-audit]] --> C5[close]
    classDef subskill stroke:#8888dd,stroke-width:2px
    class W1,W2,W3,W4 subskill
```

> Double-bordered nodes (`orient`, `impact-analysis`, `capture`, `code-simplifier`, `code-reviewer`, `security-review`, `doc-audit`) are sub-skills loaded from canon automatically — not invoked separately.

---

## Tickets

Every `sprint start` creates a ticket in `.tickets/<id>/`. Every `sprint complete` closes it. No manual ticketing, no external service, no account.

A ticket is a folder, not a card — it holds the approved plan, decisions made mid-sprint, and any QA or research notes, all as markdown files. When context resets mid-session, the agent opens the ticket and picks up exactly where it left off.

Most tools track work in a service you have to open. Canon tracks it in your repo, where your agent already is.

---

## sprint-check — the local kanban board

No server. No account. No SaaS. Just run:

```bash
sprint-check
```

It reads your project's `.tickets/` folder and `git log` and opens a local kanban board in your browser. Tickets link to commits automatically.

Tickets don't need to be created manually. Every `sprint start` creates one. Every `sprint complete` closes it. Open the board mid-session and your work is already there — no entry, no tagging, no context-switching.

### The board

![sprint-check board — light mode](meta/screenshots/board-light.png)

The sidebar shows git state, current focus from `HANDOFF.md`, recent commits, and a ticket summary — everything you and your agent need at a glance.

### Dark mode

![sprint-check board — dark mode](meta/screenshots/board-dark.png)

Toggle between light and dark with the button in the top-right corner.

### Commit intelligence

![Commit detail with related ticket](meta/screenshots/commit-detail.png)

Click any commit in the sidebar to see what changed and which ticket it likely belongs to — matched by ticket ID in the commit message or by keyword when no ID is present.

### Create tickets from the board

![New ticket modal](meta/screenshots/new-ticket.png)

`+ New ticket` opens a form pre-filled with a structured template. Type, priority, goal, and acceptance criteria — then `Create`. The ticket lands in `.tickets/` as a markdown file, immediately visible to your agent.

### Ticket completeness

![Ticket completeness checker](meta/screenshots/ticket-completeness.png)

Hover a ticket card to see what's missing — description, blueprint, decisions. The board surfaces gaps before they block your agent mid-sprint, with a direct prompt to add what's needed.

### Drag to update status

![Drag and drop ticket](meta/screenshots/drag-drop.png)

Drag any ticket card between columns to update its status instantly. No clicks, no dropdowns — the board writes the change back to `.tickets/` immediately.

### Attach docs to a ticket

![New doc dialog](meta/screenshots/new-doc.png)

Click `+ New doc` on any ticket to attach a structured document. The board suggests the right type based on ticket status:

| Doc | Suggested when | Use it to |
|---|---|---|
| **Blueprint** | Ticket is open, or in progress with no blueprint yet | Plan approach, scope, and open questions before building |
| **Decisions** | Ticket is in progress or closed | Record choices made, trade-offs, and why alternatives were ruled out — visible to future agents |
| **QA** | Ticket is in progress or closed | Write the test plan and sign-off checklist before closing |
| **Notes** | Any status | Freeform scratchpad — research, links, observations, anything that doesn't fit the others |

Docs land in `.tickets/<id>/` as markdown files and are read automatically by your agent at sprint start.

---

## The contrast

Popular agent workflow frameworks define multi-step processes with their own vocabulary — subagent-driven development, RED-GREEN-REFACTOR cycles, YAGNI — and require a separate install for each platform they support. They ask you to learn a system on top of your agent.

Canon has two commands.

| | canon | popular frameworks |
|---|---|---|
| Install | One command (`npx canon-skills@latest`) | Separate install per platform |
| Things to learn | 2 commands | Multi-step workflow + vocabulary terms |
| Built with | Markdown + bash | Methodology plugins |
| Dependencies | None | Platform plugin runtime |
| Updates | `git pull` in one repo | Plugin release per platform |
| Agent support | Claude Code, Codex, Pi | Broader (Cursor, Gemini, Copilot + more) |
| State lives in | Your repo (`.tickets/`, `HANDOFF.md`) | Plugin state |
| Audits itself | Yes (`context-check`, `doc-audit`) | No |

---

## Quick start

**1. Install**

```bash
npx canon-skills@latest
# Clones the repo to ~/Developer/canon and runs setup.
# Existing install? It pulls the latest changes instead.
```

Or clone directly:

```bash
git clone https://github.com/sunitghub/canon.git ~/Developer/canon
~/Developer/canon/skills.sh init
```

**2. Register skills in a project**

```bash
cd /path/to/your-project

~/Developer/canon/skills.sh add sprint        # plan → build → ship (includes wrapup, handoff)
~/Developer/canon/skills.sh addall            # or register all skills at once
```

**3. Start a session**

Your agent reads the registered skills and follows them — no prompt engineering, no system prompt editing, no copy-pasting.

---

## The CLI

![skills --h output](meta/screenshots/cli-help.png)

`skills.sh help <skill>` prints the full skill documentation in the terminal — discover what any skill does without opening a file.

---

## How the live-reference model works

`skills.sh add` writes one line into your project's config — not a copy of the skill, a reference:

```
# CLAUDE.md
@/Users/you/Developer/canon/skills/sprint.md

# AGENTS.md
| sprint | dev | /Users/you/Developer/canon/skills/sprint.md |
```

Claude Code reads `CLAUDE.md` at session start. The `@` prefix tells it to load the referenced file in full — which is the live skill from the canon repo. When canon updates, the next session picks up the change automatically. No re-registration.

Configuration is living, not static. Conventions learned during a sprint flow back into `AGENTS.md` on close — the codebase teaches the agent, and the agent remembers.

---

## Prerequisites

| Tool | Required | Install |
|---|---|---|
| Claude Code / Codex / Pi | Yes — at least one | [claude.ai/code](https://claude.ai/code) |
| Node.js ≥ 16 | For `npx` install only | [nodejs.org](https://nodejs.org) |

---

## Full setup guide

[`guides/AI-Agents-Setup.md`](guides/AI-Agents-Setup.md) — prerequisites, per-agent wiring, project registration, verification, and the full sprint + wrapup workflow.

---

*Make it canon.*
