# Context Doctor

A portable Claude skill that audits your repo's **agent context** (`CLAUDE.md`, `AGENTS.md`, skill
and command files, referenced specs) against context-engineering lessons for Claude 4/5 models,
prints a Summary table, and writes `claude-optimization.md` to your repo root.

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
- Rates eleven lenses — the seven core context-engineering lenses (rules→judgement,
  examples→interfaces, upfront→progressive-disclosure, repeat→simple-descriptions, memory,
  specs→rich-references, conflicting-instructions), two model-agnostic checks (checkpoint/pause
  discipline, progress-claim grounding), and two Fable-5-specific checks (reasoning-extraction
  avoidance, effort-default guidance) — each `aligned | advisory | action`.
- Prints a Summary table and an overall verdict: `lean | trim | overloaded` (no numeric score).
- Asks before writing `claude-optimization.md` to your repo root.

## Target model

Defaults to whichever Claude model is running the skill (detected from the session). Override with:

```
/context-doctor --model 5   # full checkup, includes the two Fable-5-only checks
/context-doctor --model 4   # nine lenses — skips reasoning-extraction and effort-default checks,
                             # which are false positives for Opus 4.8
```

Use `--model 4` when auditing on a different model than the one your repo actually targets in
production (e.g. running the audit on Fable 5 against a repo built for Opus 4.8).

## Run it

Just ask: "run context-doctor" (or `/context-doctor` in Claude Code). Review the Summary table, and
confirm the write when prompted.
