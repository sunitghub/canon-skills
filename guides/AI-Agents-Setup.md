# AI Agents Setup Guide

Everything a new team member needs to get Claude Code, Codex, and Pi working with this repo's skills, tools, and optimizations. Follow in order — each section builds on the previous.

---

## What this repo is

A shared library of AI agent skills, tools, standards, and automation scripts. Your projects don't copy from it — they import from it via live `@`-references. When this repo is updated, your projects pick up changes automatically on the next session.

```
AI-Skills/          ← this repo (shared library, clone once)
  skills/           ← polish, code-reviewer, security-review, ...
  tools/            ← ticket, handoff
  standards/        ← general, git
  scripts/          ← hook automation (handoff, polish trigger, pre-commit)
  guides/           ← this file and context-optimization.md
  extensions/pi/    ← Pi lifecycle extensions

your-project/       ← your work repo
  CLAUDE.md         ← @-imports pointing into AI-Skills
  AGENTS.md         ← skill table for Codex and Pi
  HANDOFF.md        ← session context (auto-managed)
```

---

## Step 1 — Clone AI-Skills to the standard path

The standard path matters. All `@`-import references and hook scripts use `~/Developer/AI-Skills`. Cloning elsewhere breaks them.

```bash
mkdir -p ~/Developer
git clone https://github.com/sunitghub/AI-Skills.git ~/Developer/AI-Skills
```

Verify:
```bash
ls ~/Developer/AI-Skills/skills.sh   # should exist
```

---

## Step 2 — Install prerequisites

**RTK** — filters verbose CLI output before it reaches the AI's token budget. Required for all agents.

```bash
brew install rtk
rtk --version   # verify
```

> If `rtk gain` fails after install, you may have the wrong `rtk` package (name collision on crates.io). Use `brew install rtk` — not `cargo install rtk`.

> Installing the binary is enough for now. The agent-specific RTK hook (`rtk init`) is wired up automatically in Step 3 by `init-agent.sh`.

**tk** — git-native task tracker used by the ticket skill and the quality pipeline hooks. Required if using ticket management.

```bash
brew tap wedow/tools
brew install ticket
tk help   # verify
```

---

## Steps 3–5 — Agent setup (automated)

Run the setup script — it handles Claude Code, Codex, and Pi, and is safe to run multiple times:

```bash
~/Developer/AI-Skills/init-agent.sh
```

It will prompt you to choose an agent (or `all`), back up any existing config files before modifying them (`.bak` extension), and report what was added vs already present.

You can also run non-interactively:
```bash
~/Developer/AI-Skills/init-agent.sh claude   # Claude Code only
~/Developer/AI-Skills/init-agent.sh codex    # Codex only
~/Developer/AI-Skills/init-agent.sh pi       # Pi only
~/Developer/AI-Skills/init-agent.sh all      # all three
```

**What it sets up per agent:**

| Agent | What gets configured |
|---|---|
| Claude Code | RTK native hook (`rtk hook claude`) via `rtk init -g --auto-patch`, plus handoff + quality hooks merged into `~/.claude/settings.json` |
| Codex | RTK instructions via `rtk init -g --codex` → writes `~/.codex/RTK.md` + `@reference` in `~/.codex/AGENTS.md` |
| Pi | Copies `extensions/pi/handoff.ts` to `~/.pi/agent/extensions/` |

**Manual fallback (if you prefer to inspect before applying):**

<details>
<summary>Claude Code — manual hook setup</summary>

```bash
rtk init -g --auto-patch   # RTK native hook (non-interactive)
```

Then merge into `~/.claude/settings.json`:
```json
{
  "hooks": {
    "Stop":             [{ "matcher": "", "hooks":     [{ "type": "command", "command": "~/Developer/AI-Skills/scripts/auto-handoff.sh" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks":     [{ "type": "command", "command": "~/Developer/AI-Skills/scripts/handoff-inject.sh" }] }],
    "PostToolUse":      [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/Developer/AI-Skills/scripts/auto-polish-trigger.sh" }] }],
    "PreToolUse":       [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/Developer/AI-Skills/scripts/pre-commit-check.sh" }] }]
  }
}
```
</details>

<details>
<summary>Codex — manual setup</summary>

```bash
rtk init -g --codex --auto-patch
```
</details>

<details>
<summary>Pi — manual setup</summary>

```bash
mkdir -p ~/.pi/agent/extensions
cp ~/Developer/AI-Skills/extensions/pi/handoff.ts ~/.pi/agent/extensions/handoff.ts
# then /reload in Pi
```
</details>

---

## Step 4 — Per-project setup

Run this once per project you want to use skills in.

### Register the core skills

```bash
cd /path/to/your-project

# Context and task management
~/Developer/AI-Skills/skills.sh add handoff
~/Developer/AI-Skills/skills.sh add ticket      # if using tk for task tracking

# Coding standards (applied automatically, no invocation needed)
~/Developer/AI-Skills/skills.sh add general
~/Developer/AI-Skills/skills.sh add git

# Quality pipeline (installs dependencies automatically)
~/Developer/AI-Skills/skills.sh add polish
```

### Verify registration

```bash
~/Developer/AI-Skills/skills.sh status
```

You should see all registered skills listed under both `CLAUDE.md` and `AGENTS.md`.

### Initialize HANDOFF.md

Tell Claude or Codex: "Initialize the handoff file" — it creates `HANDOFF.md` in the project root from the template.

---

## Verification checklist

Run through these to confirm everything is wired up correctly.

**RTK**
```bash
rtk gain        # should show "No tracking data yet" or savings stats (not an error)
rtk git status  # should run and show compact output
```

**Claude Code hooks**
```bash
cat ~/.claude/settings.json   # should contain: rtk hook claude, auto-handoff, handoff-inject, auto-polish-trigger, pre-commit-check
```

**Codex**
```bash
cat ~/.codex/AGENTS.md   # should contain @RTK.md reference
```

**Per-project**
```bash
~/Developer/AI-Skills/skills.sh status   # lists registered skills
```

---

## Skill verification

After registering skills, confirm each one is wired up and responding correctly.

| Skill | How to verify | Expected response |
|-------|--------------|-------------------|
| `general` | `skills.sh status` | Listed under CLAUDE.md @-imports |
| `git` | `skills.sh status` | Listed under CLAUDE.md @-imports |
| `ticket` | `tk ls` | Empty list or existing tickets (no error) |
| `handoff` | Tell Claude/Codex: "Initialize the handoff file" | `HANDOFF.md` created in project root |
| `code-simplifier` | Tell Claude/Codex: "Simplify the changes" | Simplification report scoped to recent changes |
| `code-reviewer` | Tell Claude/Codex: "Review my changes" | Structured report across seven dimensions |
| `security-review` | Tell Claude/Codex: "Run a security review" | Findings report or explicit "nothing flagged" |
| `polish` | Tell Claude/Codex: "Polish my changes" or `/polish` | Runs all three steps with skip reasoning for each |
| `pdf` | Tell Claude/Codex: "Extract text from [file].pdf" | Extracted content or clear error if no PDF present |

> **Standards skills** (`general`, `git`) have no invocation — they're applied automatically to every code change. Registration in `skills.sh status` is the only verification needed.

---

## Day-to-Day Workflows

### Ticketing with `tk`

`tk` is a git-native task tracker. Tickets are markdown files in `.tickets/` — committed to the repo, visible in git log, and clickable in VS Code.

**Both Claude and Codex read the same skill file** (`tools/ticket.md`) via `@`-import — one in `CLAUDE.md`, one in `AGENTS.md`. No agent-specific setup needed; skill updates propagate to both on next session start.

#### Key commands

```bash
tk create "title" [-t bug|feature|task|epic|chore] [-p 0-4] [-d "desc"]
tk ls                       # open tickets
tk ls --status=in_progress  # filter by status
tk show <id>                # full ticket detail
tk start <id>               # mark in_progress
tk close <id>               # mark closed (prefer: use approve workflow)
tk reopen <id>              # reopen a closed ticket
tk dep <id> <dep-id>        # id depends on dep-id
tk dep tree <id>            # visualize dependency graph
tk dep cycle                # detect circular dependencies
```

Priority: `0` = highest, `4` = lowest. Default is `2`.

#### Standard workflow

1. **Create** — Ask the agent: *"Create a ticket to add X."*
   The agent runs `tk create` and returns the ticket ID.

2. **Implement** — Ask the agent: *"Implement ticket `<id>`."*
   The agent runs `tk start <id>`, does the work, and prepends `<id>:` to every commit.

3. **Test** — Review the changes yourself.

4. **Approve** — Tell the agent: *"Approve `<id>`."*
   The agent runs the full pipeline (see below).

#### Approve pipeline

Say **"approve `<id>`"** (or "ship it", "approve and close") after testing. The agent runs:

1. `tk dep cycle` — aborts if cycles are detected
2. `tk dep tree <id>` — warns if any dependencies are still open; asks whether to proceed or close them first
3. Closes resolved dependencies bottom-up (leaves first, then parents)
4. `tk close <id>`
5. Runs `/polish` on all files modified since the ticket was started
6. Runs `/simplify` on those same files
7. Runs `/security-review` only if you pass `--security` or explicitly request it

For multiple tickets: add all IDs — `"approve nw-01, nw-02, nw-03"`. The agent closes all of them first, then runs a single polish+simplify pass across the combined set of modified files.

Agents are instructed never to call `tk close` directly — always through the approve pipeline so polish and simplify never get skipped.

#### Dependency management

```bash
# Mark that ticket nw-05 cannot close until nw-03 is done
tk dep nw-05 nw-03

# Inspect the tree before approving
tk dep tree nw-05

# Check for cycles before closing a milestone
tk dep cycle
```

If a dependency is still open when you approve, the agent will warn you and ask whether to close the dep first or proceed anyway.

---

### Polish — Quality Pipeline

Polish is the quality gate that runs at the end of every approve. It can also be triggered manually at any time.

#### How to trigger

```
/polish
```
Or: "Polish the changes" / "Polish ticket nw-42."

#### Pipeline

```
code-simplifier → code-reviewer → security-review
```

Each step is skipped if it doesn't apply — the agent states why in one line when skipping.

| Step | Skipped when |
|------|-------------|
| code-simplifier | Single-line change, or docs/config only |
| code-reviewer | Single-line fix with no design implications, or purely mechanical change |
| security-review | No security-sensitive files changed (auth, DB queries, user input, API endpoints, crypto, session management, file I/O, env/secret access) |

#### What each step produces

**Simplifier** — rewrites recently modified code for clarity without changing behavior: reduces nesting, eliminates redundancy, improves names, removes obvious comments. Scope is limited to files touched in the current session.

**Reviewer** — structured report across seven dimensions: correctness, maintainability, readability, efficiency, security, edge cases, test coverage. Format: Critical → Improvements → Nitpicks → Recommendations.

**Security review** — high-confidence findings only. Traces data flow end-to-end before flagging anything. Reports severity (Critical / High / Medium / Low) with location, pattern, evidence, impact, and fix.

#### Final output format

```
## Polish Report — <ticket or task>

### code-simplifier
- <what was simplified and where>

### code-reviewer
- [Critical] ...
- [Improvement] ...

### security-review
- [High] ...
```

Address criticals before committing. Improvements and nitpicks are at your discretion.

#### Auto-trigger

The `PostToolUse` hook (`auto-polish-trigger.sh`) watches for ticket close events and can trigger polish automatically. The approve workflow handles this explicitly — manual `/polish` is mainly for ad-hoc cleanup outside of the ticket flow.

---

## Staying updated

When this repo is updated with improved skills or new scripts:

```bash
cd ~/Developer/AI-Skills
git pull
```

**That's it for existing skills.** Because your project's `CLAUDE.md` uses live `@`-import references into this repo, Claude Code picks up updated skill content automatically on the next session. Hook scripts update immediately too — they're called by path.

**For newly added skills:** you'll need to opt in explicitly:
```bash
~/Developer/AI-Skills/skills.sh add <new-skill> /path/to/your-project
```

Check what's new:
```bash
~/Developer/AI-Skills/skills.sh list
```

---

## How the automation works end-to-end

See [`guides/context-optimization.md`](context-optimization.md) for a full explanation of the token optimization, session handoff, and quality pipeline — including why each piece is designed the way it is.
