---
name: handoff
description: Session context handoff protocol — keeps Claude and Codex in sync across repos and agents
category: tools
tags: [context, memory, handoff, multi-agent]
hidden: true
---

# Handoff — Session Context Protocol

Preserves working context across sessions and agents using a `HANDOFF.md` file in the repo root. Bridges the gap between Claude, Codex, Pi, and any future agent — so the next session picks up where the last one left off.

---

## The problem it solves

AI agents don't share memory. When you switch from Codex to Claude (or vice versa), or when a context window fills up mid-session, the new agent starts completely cold. Without handoff, you spend the first 10 minutes re-explaining where things stand.

`HANDOFF.md` is the shared state — a lightweight, git-tracked snapshot that any agent can read.

---

## Getting Started — Pick Your Level

Choose the level that matches your project's complexity. Each level builds on the previous.

---

### Level 1 — Manual (any agent, no hooks)

Best for: simple projects, occasional agent switching.

**Step 1 — Register the skill in your project:**
```bash
<path-to-canon>/skills.sh add handoff /path/to/your/project
```

**Step 2 — Verify:**
```bash
<path-to-canon>/skills.sh status /path/to/your/project
```

**Step 3 — Initialize `HANDOFF.md` in the repo root:**

Tell the agent: "Initialize the handoff file" — it creates it from the template. Or run:
```bash
curl -s https://raw.githubusercontent.com/sunitghub/canon/main/tools/handoff.md \
  | awk '/^```markdown$/,/^```$/{if(!/^```/)print}' > HANDOFF.md
```

Or just create it manually using the template at the bottom of this file.

**Step 4 — Use it:**
- **Session start**: Tell the agent "Read HANDOFF.md and summarize where we are."
- **During session**: The agent updates it when significant decisions are made.
- **Session end**: Tell the agent "wrap up" — it updates `HANDOFF.md` and commits it.
- **Next session / switching agents**: The next agent reads `HANDOFF.md` before starting work.

#### Scenario — switching from Claude to Codex mid-feature

**Setup:** You're building a rate-limiter in Claude. Halfway through you need to switch to Codex.

---

**In Claude** — you've implemented `auth/rate_limiter.py` but haven't touched `auth/views.py` yet.

You say: "wrap up"

Claude writes and commits `HANDOFF.md`:
```markdown
# Handoff

_Last updated: 2026-04-20 14:30 by Claude (claude-sonnet-4-6)_

## Current Focus
Wiring the rate-limiter middleware into the auth views.

## In Progress
- auth/rate_limiter.py: done — RateLimiter class implemented, tests passing
- auth/views.py: not started — needs @rate_limit decorator on login endpoint

## Recent Decisions
- Used Redis INCR + EXPIRE over a DB counter — atomic, no locking needed
- Keyed on user IP, not session — handles logged-out brute force

## Dead Ends
- Tried sliding window algorithm — too complex, fixed window is sufficient here

## Next Steps
1. Add @rate_limit to auth/views.py login endpoint
2. Add integration test for rate limit exceeded (429 response)
3. Run /wrapup when done
```

---

**You open Codex** on the same repo.

Codex reads `AGENTS.md` → sees handoff skill → reads `HANDOFF.md` immediately.

Codex says: "Resuming — rate-limiter is done, next is wiring it into `auth/views.py` login endpoint."

You say nothing about context. Codex already knows.

---

### Level 2 — Automated (Claude Code with hooks)

Best for: long sessions, frequent context limit hits, heavy Claude Code usage.

Adds two hooks to Claude Code's global settings:
- **`Stop` hook** — auto-saves a snapshot of git state to `HANDOFF.md` whenever Claude stops. Safety net for context window exhaustion.
- **`UserPromptSubmit` hook** — injects `HANDOFF.md` into the first prompt of each session. Claude wakes up knowing where things stand without you having to ask.

**Step 1 — Complete Level 1 first.**

**Step 2 — Copy the two hook scripts to your canon repo:**
```bash
# Already included in canon at:
ls <path-to-canon>/scripts/
# auto-handoff.sh   — Stop hook
# handoff-inject.sh — UserPromptSubmit hook
```

**Step 3 — Add the hooks to `~/.claude/settings.json`:**

Open `~/.claude/settings.json` and add to the `"hooks"` object:
```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "<path-to-canon>/scripts/auto-handoff.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "<path-to-canon>/scripts/handoff-inject.sh"
          }
        ]
      }
    ]
  }
}
```

**Step 4 — Verify hooks are active:**
```bash
cat ~/.claude/settings.json | grep -A5 "Stop\|UserPromptSubmit"
```

**What happens automatically from here:**
- Open a project → Claude reads `HANDOFF.md` silently on your first message (once per 4-hour window)
- Context window fills → Stop hook saves current git state to `HANDOFF.md` and commits it
- Next session → Claude picks up from the snapshot, no re-explaining needed

#### Scenario — context window exhausted mid-session

**Setup:** Long session implementing OAuth. No hooks yet → context dies, handoff never written. With Level 2 hooks, here's what happens instead.

---

**Hour 1** — Claude implements `auth/oauth.py`, `auth/tokens.py`. Working tree has changes. Claude stops responding (end of a turn).

Stop hook fires → `auto-handoff.sh` runs → sees uncommitted files → appends snapshot:
```markdown
<!-- HANDOFF-SNAPSHOT:START 2026-04-20 11:15 branch:feat/oauth -->
**Modified files:**
M auth/oauth.py
M auth/tokens.py
?? auth/tests/test_oauth.py

**Recent commits:**
a1b2c3d Add OAuth provider config
d4e5f6a Scaffold token refresh flow

**In-progress tickets:**
nw-14 Implement OAuth login (in_progress)
<!-- HANDOFF-SNAPSHOT:END -->
```

**Hour 3** — Context window fills. Claude stops mid-sentence. Can't respond.

Stop hook fires again → new snapshot prepended, old one kept (FIFO, max 2):
```markdown
<!-- HANDOFF-SNAPSHOT:START 2026-04-20 13:42 branch:feat/oauth -->
**Modified files:**
M auth/oauth.py
M auth/tokens.py
M auth/middleware.py
?? auth/tests/test_oauth.py

**Recent commits:**
...
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-04-20 11:15 branch:feat/oauth -->
...prior state...
<!-- HANDOFF-SNAPSHOT:END -->
```

---

**Next day — new Claude session.**

`handoff-inject.sh` fires on your first message → injects `HANDOFF.md` silently.

Claude says: "Resuming OAuth work. You were mid-session when context ran out — `auth/middleware.py` was modified but `test_oauth.py` was untracked. Ticket nw-14 in progress. Where do you want to pick up?"

You say: "Tests." Claude starts immediately, no context re-explaining.

---

### Level 3 — Full multi-agent (Claude + Codex + Pi)

Best for: teams or workflows that switch between multiple agents on the same repo.

**The shared file is still `HANDOFF.md`** — all agents read and write the same file. What differs is how each agent's automation is wired.

#### Codex

Codex reads `AGENTS.md` natively. Since `skills.sh add handoff` already writes to `AGENTS.md`, Codex will follow the handoff instructions automatically.

For the Stop hook equivalent, add to `~/.codex/config.toml`:
```toml
[hooks]
on_session_end = "<path-to-canon>/scripts/auto-handoff.sh"
```
> Note: Codex hook support varies by version. Check `codex --help` or the Codex docs for your installed version.

#### Pi

Pi uses TypeScript extensions with lifecycle events. The handoff extension is included in canon at `extensions/pi/handoff.ts`. It hooks into `session_start`, `input`, and `agent_end` — equivalent to Claude Code's `UserPromptSubmit` and `Stop` hooks.

**Install globally** (applies to all Pi projects):
```bash
cp <path-to-canon>/extensions/pi/handoff.ts ~/.pi/agent/extensions/handoff.ts
```

**Install per project** (applies to this project only):
```bash
mkdir -p .pi/extensions
cp <path-to-canon>/extensions/pi/handoff.ts .pi/extensions/handoff.ts
```

**Reload without restarting Pi:**
```
/reload
```

**What the extension does:**
- `session_start` — resets the injection flag; warns if `HANDOFF.md` exceeds 80 lines
- `input` — prepends `HANDOFF.md` to your first message of each session (once only)
- `agent_end` — runs `auto-handoff.sh` to snapshot git state when working tree has changes

#### Manual fallback (any agent without hook support)

Before ending any session, say: **"wrap up"** — the agent updates `HANDOFF.md` and commits it. This works in every agent that has loaded the handoff skill.

#### Scenario — three-agent rotation on the same repo

**Setup:** `blissful-chants-videos` repo. Morning in Claude, afternoon in Codex, evening quick check in Pi.

---

**Morning — Claude**

You work on the video upload pipeline. Context is getting long.

You say: "wrap up"

Claude writes `HANDOFF.md` with focus, decisions, next steps. Commits it. Pushes.

---

**Afternoon — Codex**

You open the same repo. Codex reads `AGENTS.md` → handoff skill loaded → reads `HANDOFF.md`.

Codex: "Resuming video upload pipeline. Upload chunking is done, thumbnail generation is next. Decided against FFmpeg — using sharp instead because it's already a dependency."

You say: "Continue." Codex picks up thumbnail generation.

Before you stop: "wrap up" → Codex updates `HANDOFF.md` with new state. Commits.

---

**Evening — Pi**

Pi reads the project's `AGENTS.md` → sees handoff → reads `HANDOFF.md`.

Pi: "Thumbnail generation implemented. Remaining: wire thumbnails into the video metadata API (Next Steps #1). One open question: thumbnail storage — S3 bucket or same volume as videos?"

You answer the question. Pi updates `HANDOFF.md`. Commits.

---

All three agents shared one file. No Slack messages, no copy-pasting context, no re-explaining.

---

## How the hooks behave

### `Stop` hook (`auto-handoff.sh`)

- Runs every time Claude stops responding
- **Skips silently** if the working tree is clean (nothing changed)
- If there are uncommitted changes: appends a timestamped auto-snapshot to `HANDOFF.md`
- Commits just `HANDOFF.md` — no other files touched
- Safe to run frequently — idempotent

### `UserPromptSubmit` hook (`handoff-inject.sh`)

- Runs before every user message is sent to Claude
- **Injects `HANDOFF.md` only once per 4-hour window** per project — not on every prompt
- If no `HANDOFF.md` exists in the project: exits silently, no injection
- Token cost: ~200-400 tokens on session start only, zero overhead after

---

## HANDOFF.md Template

```markdown
# Handoff

_Last updated: YYYY-MM-DD HH:MM by <agent> (<model>)_

## Current Focus
One sentence: what are we working on right now.

## In Progress
- file/path or ticket-id: what's started but not finished

## Recent Decisions
- Decision made and WHY (not what — the diff shows what)

## Discoveries
- Non-obvious facts found through investigation — filter rules, counts, env gotchas, constraints not visible in code

## Dead Ends
- What was tried and didn't work, so the next agent doesn't repeat it

## Open Questions
- Unresolved things that need a decision before proceeding

## Next Steps
1. First concrete next action
2. Second
```

---

## Rules

- **Keep it short.** This is a handoff note, not a journal. Prune old entries freely.
- **Current Focus is one sentence max.**
- **Decisions capture WHY** — the git diff already shows what changed.
- **Always commit before ending a session.** An uncommitted handoff is useless.
- **No secrets, credentials, or env-specific values** in this file — it's committed to git.
- **The auto-snapshot section** (added by the Stop hook) is mechanical. Fill in Current Focus and Decisions manually for full context.
