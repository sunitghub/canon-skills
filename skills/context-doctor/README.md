# Context Doctor

A portable Claude skill that audits your repo's **agent context** (`CLAUDE.md`, `AGENTS.md`, skill
and command files, referenced specs) against the seven context-engineering lessons for modern Claude
models, prints a Summary table, and writes `claude-optimization.md` to your repo root.

Lessons reference: https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models

Self-contained — no build tools, no other skills, no network.

## Install

**Claude Code** — unzip into your repo's skills directory:

```bash
unzip context-doctor.zip -d .claude/skills/
# → .claude/skills/context-doctor/SKILL.md
```

Then invoke it in Claude Code:

```
/context-doctor
```

**Claude Desktop** — Settings → Skills → add a skill, and upload the `context-doctor` folder (or its
`SKILL.md`).

## What it does

- Reads your agent-context files (never runs your app, never edits your files).
- Rates seven lenses — rules→judgement, examples→interfaces, upfront→progressive-disclosure,
  repeat→simple-descriptions, memory, specs→rich-references, conflicting-instructions —
  each `aligned | advisory | action`.
- Prints a Summary table and an overall verdict: `lean | trim | overloaded` (no numeric score).
- Asks before writing `claude-optimization.md` to your repo root.

## Run it

Just ask: "run context-doctor" (or `/context-doctor` in Claude Code). Review the Summary table, and
confirm the write when prompted.
