# canon

> One repo. Every agent. Consistent behaviors across all your projects.

canon is a shared skill library for AI coding agents — Claude Code, Codex, and Pi. Register skills once and they live-import into any project. Update the canon, and every project picks up the change automatically on the next session.

---

## The problem

You've carefully configured an AI agent: enforce your git conventions, run a quality check before committing, keep context across sessions. Then you start a new project — and explain it all from scratch.

canon solves this with a **live-reference model**. Skills live in one place and are `@`-imported directly into each project's `CLAUDE.md` and `AGENTS.md`. No copies. No drift. One source of truth for every agent, every project.

---

## What's inside

| Skill | Category | What it does |
|---|---|---|
| `wrapup` | skills | Quality pipeline: simplify → review → security — scoped to current unit of work |
| `code-reviewer` | skills | Structured review across correctness, maintainability, security, edge cases, and coverage |
| `code-simplifier` | skills | Refactor recently modified code for clarity without changing behavior |
| `security-review` | skills | High-confidence vulnerability detection — traces data flow before flagging |
| `handoff` | tools | Session context that persists across agents, resets, and long gaps |
| `ticket` | tools | Git-native task tracking with `tk` *(optional)* |
| `general` | standards | Language-agnostic coding principles, applied automatically |
| `git` | standards | Commit, branch, and PR conventions, applied automatically |

---

## Quick start

**1. Clone**

```bash
git clone https://github.com/sunitghub/canon.git ~/Developer/canon
export SKILLS=~/Developer/canon
```

**2. Wire your agents**

```bash
$SKILLS/skills.sh init        # Claude Code only
$SKILLS/init-agent.sh all     # Claude Code + Codex + Pi
```

> RTK and `tk` are optional. Setup detects them and wires their hooks if present; everything else works without them.

**3. Register skills in a project**

```bash
cd /path/to/your-project

$SKILLS/skills.sh add general   # coding standards — auto-applied, no invocation needed
$SKILLS/skills.sh add git       # git conventions — auto-applied
$SKILLS/skills.sh add wrapup    # quality pipeline
$SKILLS/skills.sh add handoff   # session context across resets
```

Start a session. Your agent now follows your standards, runs quality checks on demand, and maintains context across conversations.

---

## How the live-reference model works

`skills.sh add` writes a single line into your project's config files — not a copy of the skill, a reference to it:

```
# CLAUDE.md — Claude Code reads this on every session start
@/path/to/canon/standards/general.md

# AGENTS.md — Codex and Pi read this
| general | standards | /path/to/canon/standards/general.md |
```

When canon is updated, every project picks up the new version automatically. No re-registration. No copying. To opt into a new skill: one command. To remove one: one command.

---

## The CLI

```
skills.sh list                     List all available skills
skills.sh add <skill> [dir]        Register a skill into a project (default: cwd)
skills.sh remove <skill> [dir]     Unregister a skill from a project
skills.sh status [dir]             Show what's registered in a project
skills.sh init                     Wire Claude Code hooks to this install location
skills.sh help <skill>             Show full documentation for a skill
```

---

## Prerequisites

| Tool | Required | Install |
|---|---|---|
| Claude Code / Codex / Pi | Yes — at least one | [claude.ai/code](https://claude.ai/code) |
| RTK | No — recommended | `brew install rtk` (macOS) · `cargo install rtk` (Linux/WSL) |
| tk | No — for `ticket` skill only | `brew install wedow/tools/ticket` |

---

## Full setup guide

See [`guides/AI-Agents-Setup.md`](guides/AI-Agents-Setup.md) for the complete walkthrough — prerequisites, per-agent wiring, per-project registration, verification, and day-to-day workflows including the ticket approve pipeline and wrapup quality gate.
