# AI Agents Setup Guide

Everything a new team member needs to get Claude Code, Codex, and Pi working with this repo's skills, tools, and optimizations. Follow in order — each section builds on the previous.

---

## What this repo is

A shared library of AI agent skills, tools, standards, and automation scripts. Your projects don't copy from it — they import from it via live `@`-references. When this repo is updated, your projects pick up changes automatically on the next session.

```
canon/              ← this repo (shared library, clone once)
  skills/           ← sprint, wrapup, capture, pdf (+ hidden deps: code-reviewer, code-simplifier, security-review)
  tools/            ← handoff, ticket, tkt.sh (infrastructure deps — loaded via sprint, not listed in catalog)
  standards/        ← efficiency (coding, git, token-efficiency — one unified file)
  scripts/          ← hook automation (handoff, wrapup trigger, pre-commit)
  guides/           ← this file and context-optimization.md
  extensions/pi/    ← Pi lifecycle extensions

your-project/       ← your work repo
  CLAUDE.md         ← @-imports pointing into canon
  AGENTS.md         ← skill table + inlined standards for Codex and Pi
  HANDOFF.md        ← session context (auto-managed)
```

---

## Step 1 — Clone canon

Clone the repo anywhere you like. The scripts self-locate at runtime.

```bash
git clone https://github.com/sunitghub/canon.git ~/Developer/canon
```

Then set a shell variable for the rest of this guide (substitute your actual clone path):

```bash
export SKILLS=~/Developer/canon
```

Verify:
```bash
ls $SKILLS/skills.sh   # should exist
```

---

## Step 2 — Install prerequisites

**RTK** (optional, recommended) — filters verbose CLI output before it hits the AI's token budget. Saves 60–90% of tokens on common operations. Setup detects whether it's installed and wires the hook automatically if so; skills work without it.

```bash
# macOS
brew install rtk

# WSL / Linux
cargo install rtk
```

```bash
rtk --version   # verify
```

> If `rtk gain` fails after install, you may have the wrong package (name collision on crates.io). Use `brew install rtk` — not `cargo install rtk`.

**tkt** — bundled minimal ticket tool, included with canon. No install needed. `skills add sprint` adds it automatically and offers to put it on your PATH.

---

## Steps 3–5 — Agent setup (automated)

**Claude Code only** — run the lightweight init command:

```bash
$SKILLS/skills.sh init
```

> Re-run `skills.sh init` any time you move or rename the canon folder — it rewires the hook paths in `~/.claude/settings.json` to the new location.

**Claude Code + Codex + Pi** — run the full setup script. It is safe to run multiple times:

```bash
$SKILLS/init-agent.sh
```

It will prompt you to choose an agent (or `all`), back up any existing config files before modifying them (`.bak` extension), and report what was added vs already present.

You can also run non-interactively:
```bash
$SKILLS/init-agent.sh claude   # Claude Code only
$SKILLS/init-agent.sh codex    # Codex only
$SKILLS/init-agent.sh pi       # Pi only
$SKILLS/init-agent.sh all      # all three
```

**What it sets up per agent:**

| Agent | What gets configured |
|---|---|
| Claude Code | Handoff + quality hooks merged into `~/.claude/settings.json`. RTK hook wired automatically if `rtk` is installed; skipped with a hint if not. |
| Codex | RTK instructions via `rtk init -g --codex` → writes `~/.codex/RTK.md` + `@reference` in `~/.codex/AGENTS.md` (skipped if RTK absent). |
| Pi | Copies `extensions/pi/handoff.ts` to `~/.pi/agent/extensions/` |

**Manual fallback (if you prefer to inspect before applying):**

<details>
<summary>Claude Code — manual hook setup</summary>

```bash
rtk init -g --auto-patch   # RTK native hook (non-interactive)
```

Then either run `$SKILLS/skills.sh init` (recommended), or merge manually into `~/.claude/settings.json` (replace `<SKILLS>` with your actual clone path):
```json
{
  "hooks": {
    "Stop":             [{ "matcher": "", "hooks":     [{ "type": "command", "command": "<SKILLS>/scripts/auto-handoff.sh" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks":     [{ "type": "command", "command": "<SKILLS>/scripts/handoff-inject.sh" }] }],
    "PostToolUse":      [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "<SKILLS>/scripts/auto-polish-trigger.sh" }] }],
    "PreToolUse":       [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "<SKILLS>/scripts/pre-commit-check.sh" }] }]
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
cp $SKILLS/extensions/pi/handoff.ts ~/.pi/agent/extensions/handoff.ts
# then /reload in Pi
```
</details>

---

## Step 6 — Per-project setup

Run this once per project you want to use skills in.

### Register skills

**All at once** (recommended for new projects):

```bash
cd /path/to/your-project
$SKILLS/skills.sh addall
```

**Or pick individually:**

```bash
cd /path/to/your-project

# Full dev workflow — sprint covers planning, quality, and tickets
$SKILLS/skills.sh add sprint

# Optional extras
$SKILLS/skills.sh add pdf          # PDF read/extract/merge/split
```

`addall` is idempotent — safe to re-run if new skills have been added to canon since you last registered.

> **Standards and deps are auto-injected.** Every `skills.sh add` call automatically injects the `efficiency` standard (coding principles, git conventions, token-efficiency rules). Skill deps like `code-reviewer`, `handoff`, and `ticket` are wired silently — not shown in `skills list` or registered explicitly.

### Verify registration

```bash
$SKILLS/skills.sh status          # or: skills.sh --scan /path/to/your-project
```

This checks registered skills, inline standard freshness, and broken `@`-import paths. It reports issues and tells you exactly what to run to fix them.

### Initialize HANDOFF.md

`handoff` is a dep of `sprint` and loaded automatically. To initialize the file, tell Claude or Codex: "Initialize the handoff file" — it creates `HANDOFF.md` in the project root from the template.

---

## Verification checklist

Run through these to confirm everything is wired up correctly.

**RTK** (if installed)
```bash
rtk gain        # should show "No tracking data yet" or savings stats (not an error)
rtk git status  # should run and show compact output
```

**Claude Code hooks**
```bash
cat ~/.claude/settings.json   # should contain: auto-handoff, handoff-inject, auto-polish-trigger, pre-commit-check (plus rtk hook if RTK is installed)
```

**Codex** (if RTK installed)
```bash
cat ~/.codex/AGENTS.md   # should contain @RTK.md reference
```

**Per-project**
```bash
$SKILLS/skills.sh status   # lists registered skills
```

---

## Skill verification

After registering skills, confirm each one is wired up and responding correctly.

| Skill | How to verify | Expected response |
|-------|--------------|-------------------|
| `sprint` | `"Start a sprint for X"` | Sprint brief produced — files, acceptance criteria, blockers listed — awaits approval |
| `efficiency` | `skills.sh status` | Listed under CLAUDE.md @-imports; `[ok]` in status output |
| `wrapup` | `"Wrapup the changes"` or `/wrapup` | Runs simplifier → reviewer → security-review with skip reasoning |
| `capture` | Make a non-obvious discovery mid-session | Agent writes to `## Discoveries` in HANDOFF.md without prompting |
| `pdf` | `"Extract text from [file].pdf"` | Extracted content or clear error if no PDF present |
| `ticket` | `tkt ls` | Empty list or existing tickets (no error) |

> `efficiency` applies automatically — no invocation. `capture` fires automatically — no invocation needed. `ticket` and `handoff` are deps of sprint — wired silently, not shown in `skills list`.

---

## Day-to-Day Workflows

### How it all fits together

```
                        CANON DEV LIFECYCLE
    ┌──────────────┬──────────────────────┬────────────────────┐
    │   PLAN       │       BUILD          │       SHIP         │
    │  sprint start│    [write code]      │  sprint complete   │
    ├──────────────┼──────────────────────┼────────────────────┤
    │ reads:       │                      │ wrapup:            │
    │ HANDOFF.md   │  capture (auto)      │  simplify          │
    │ DECISIONS.md │  fires on discovery  │  → code review     │
    │ sprint files │  → HANDOFF.md        │  → security        │
    │              │    ## Discoveries    │                    │
    │ creates:     │  → project memory    │ acceptance check   │
    │ blueprint.md │                      │                    │
    │ acceptance.md│                      │ DECISIONS.md update│
    │              │                      │                    │
    │ tkt start    │                      │ tkt close          │
    │ ↓ awaits     │                      │                    │
    │   approval   │                      │                    │
    └──────────────┴──────────────────────┴────────────────────┘

    Automatic (no user action needed):
      Session start → handoff-inject reads HANDOFF.md into first prompt
      Mid-session   → capture writes discoveries to HANDOFF.md
      Session end   → auto-handoff snapshots git state to HANDOFF.md

    Ad-hoc (outside a sprint):
      /wrapup       → quality check on any code without a sprint
      /capture <x>  → force-record a discovery the agent missed
```

---

### Sprint — Full Dev Workflow

Sprint is the primary workflow. Two commands replace the separate tkt, wrapup, and capture invocations.

#### sprint start

Say **"sprint start"**, **"start a sprint for X"**, or **"let's work on X"**. The agent:

1. Creates a ticket (`tkt create`) if none is active, then runs `tkt start <id>`
2. Creates planning files in `.tickets/<id>/`:
   - `blueprint.md` — files to inspect, files to create/modify, step-by-step build plan
   - `acceptance.md` — specific, binary conditions that define "done"
3. Reads `DECISIONS.md` (durable architecture decisions) and `HANDOFF.md` (current state)
4. Produces a **sprint brief**: what the sprint accomplishes, files expected to change, acceptance criteria, any constraints — and waits for your approval before writing code

#### sprint complete

Say **"sprint complete"**, **"approve"**, or **"ship it"**. The agent:

1. Runs the **wrapup pipeline** (simplify → review → security) on all modified files
2. Validates every item in `acceptance.md` — ✓ met, ✗ not met, ? uncertain. Stops if anything fails
3. Appends any new durable decisions to `DECISIONS.md` (the WHY, not the what)
4. Updates `HANDOFF.md ## Next Steps`
5. Closes the ticket: `tkt close <id>`

#### DECISIONS.md

Sprint keeps a `DECISIONS.md` at the repo root — a durable log of non-obvious architectural choices. Separate from `HANDOFF.md` (which is temporal session state). Sprint start reads it; sprint complete writes to it.

```markdown
# Decisions

| Date | Decision | Reason |
|---|---|---|
| 2026-05-17 | Amounts stored as integer cents | Avoid float precision bugs |
```

---

### Ticketing with `tkt`

`tkt` is a minimal ticket tool bundled with canon. Tickets are markdown files in `.tickets/` — committed to the repo, visible in git log, and clickable in VS Code. No external install needed. Sprint manages the tkt lifecycle automatically; use `tkt` directly for standalone queries.

#### Key commands

```bash
tkt create "title" [-t bug|feature|task|epic|chore] [-p 0-4] [-d "desc"]
tkt ls                        # list all tickets
tkt ls --status=in_progress   # filter by status
tkt show <id>                 # full ticket detail
tkt start <id>                # mark in_progress
tkt close <id>                # mark closed (prefer: sprint complete)
tkt reopen <id>               # reopen a closed ticket
```

Priority: `0` = highest, `4` = lowest. Default is `2`. IDs are short random strings (e.g. `t-8ms5`).

> Need dependency tracking, tags, or assignees? Install [ticket](https://github.com/wedow/ticket) (`brew install ticket`) — same `.tickets/` format, fully compatible.

---

### Knowledge Capture — Mid-Session Discoveries

The `capture` skill ensures non-obvious findings are recorded immediately so they survive context compaction and session switches.

**Automatic** — no action needed. When the agent discovers something non-obvious (filter rules found by comparing data, numerical facts not in code, environment gotchas, architecture decisions with non-obvious WHY), it immediately:
1. Appends to `HANDOFF.md` under `## Discoveries`
2. Saves a project memory

**Explicit trigger** — when you want to force-record something the agent missed:

| Agent | Trigger |
|---|---|
| Claude Code | `/capture <text>` |
| Codex | "Capture this" / "Record this in discoveries" |
| Pi | Same as Codex — natural language |

---

### Wrapup — Ad-hoc Quality Pipeline

Wrapup runs automatically inside `sprint complete`. Use it directly for quality checks on code written outside the sprint workflow.

```
/wrapup
```
Or: "Wrapup the changes" / "Wrapup the auth refactor."

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

#### Output format

```
## Wrapup Report — <description of work>

### code-simplifier
- <what was simplified and where>

### code-reviewer
- [Critical] ...
- [Improvement] ...

### security-review
- [High] ...
```

Address criticals before committing. Improvements and nitpicks are at your discretion.

---

## Staying updated

When this repo is updated with improved skills, standards, or scripts:

```bash
cd $SKILLS && git pull
```

**Hook scripts** update immediately — they're called by path, so the new version runs on the next session.

**Skill content** in `CLAUDE.md` (Claude) is live `@`-import references — Claude picks up changes automatically on the next session.

**Inline standards** in `AGENTS.md` (Codex, Pi) are a static copy and need an explicit refresh to pick up changes:

```bash
$SKILLS/skills.sh refresh /path/to/your-project
```

`refresh` re-registers every skill already in the project, replaces any outdated inline standard blocks in `AGENTS.md`, and heals stale `@`-import paths — all in one command.

**For newly added skills** (opt in individually or all at once):
```bash
$SKILLS/skills.sh addall /path/to/your-project        # register any new skills
$SKILLS/skills.sh add <new-skill> /path/to/your-project  # or just one
```

**Check for issues before refreshing:**
```bash
$SKILLS/skills.sh status /path/to/your-project
```

Reports stale paths, outdated inline standards, and broken `@`-imports — with a one-line fix suggestion when anything is out of date.

Check what skills are available:
```bash
$SKILLS/skills.sh list
```

---

## How the automation works end-to-end

See [`guides/context-optimization.md`](context-optimization.md) for a full explanation of the token optimization, session handoff, and quality pipeline — including why each piece is designed the way it is.
