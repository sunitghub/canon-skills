---
marp: true
theme: default
paginate: true
style: |
  section {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    font-size: 1.1rem;
    padding: 2rem 3rem;
  }
  h1 { font-size: 2rem; margin-bottom: 0.5rem; }
  h2 { font-size: 1.5rem; color: #444; border-bottom: 2px solid #eee; padding-bottom: 0.3rem; }
  h3 { font-size: 1.1rem; color: #555; margin-top: 1.2rem; margin-bottom: 0.3rem; }
  pre { background: #f5f5f5; border-radius: 6px; font-size: 0.85rem; }
  code { background: #f0f0f0; padding: 0.1em 0.3em; border-radius: 3px; }
  table { width: 100%; border-collapse: collapse; font-size: 0.95rem; }
  th { background: #f0f0f0; }
  td, th { padding: 0.4rem 0.7rem; border: 1px solid #ddd; }
  .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 2rem; }
  blockquote { border-left: 4px solid #0069ff; padding-left: 1rem; color: #333; font-style: normal; }
---

# Canon — AI Agent Skills Library {data-background-image="octave-title-bg.png" data-background-size="70%" data-background-position="bottom right" data-background-opacity="0.9"}

::: {.canon-tagline}
the canonical set of skills, tools, and standards for AI-assisted development
:::

Shared skills and automation for Claude Code, Codex, and Pi

**Plan → Build → Ship** with minimal effort, maximum continuity

---

# One install. Two commands.

```bash
$SKILLS/skills.sh add sprint
```

**sprint start** — *"sprint start"* / *"let's work on X"*

```
→ ticket created
→ blueprint.md + acceptance.md written
→ DECISIONS.md + HANDOFF.md read
→ subsystem mapped (orient) — before any edit
→ gray areas grilled → impact rated
→ sprint brief produced
→ waits for approval before writing any code
```

**sprint complete** — *"sprint complete"* / *"approve"* / *"ship it"*

```
→ wrapup: simplify → review → security
→ each acceptance criterion verified
→ stops and fixes if any criterion fails
→ DECISIONS.md written
→ conventions check → AGENTS.md (confirmed before writing)
→ HANDOFF.md, ticket closed
```

---

# Architecture — leaf to root

<div class="lifecycle-flow">
  <div class="lifecycle-box plan">PLAN</div>
  <div class="lifecycle-arrow plan-build"></div>
  <div class="lifecycle-box build">BUILD</div>
  <div class="lifecycle-arrow build-ship"></div>
  <div class="lifecycle-box ship">SHIP</div>
</div>
<div class="lifecycle-desc">
  <span class="plan-d">tkt · orient · blueprint.md<br>acceptance.md · DECISIONS.md</span>
  <span class="build-d">capture (auto)<br>efficiency (always on)</span>
  <span class="ship-d">wrapup → simplify<br>→ review → security</span>
</div>

```
sprint start         sprint complete
     │                     │
     ▼                     ▼
  blueprint.md         wrapup pipeline
  acceptance.md        acceptance check
  DECISIONS.md read    DECISIONS.md write
  HANDOFF.md read      conventions → AGENTS.md
  orient (subsystem)   HANDOFF.md update
  tkt start            tkt close

Session hooks (automatic):
  handoff-inject → reads HANDOFF.md on session start
  auto-handoff   → snapshots git state on session end
```

---

# Layer 1 — Session continuity

**Pain:** Every new session, or every context window exhaustion, the agent starts cold.

**Solution:** `HANDOFF.md` — a git-tracked file holding current focus, in-progress work, and recent discoveries.

Two hooks automate it entirely:

| Hook | When | What |
|---|---|---|
| `handoff-inject` | Session start | Injects `HANDOFF.md` into first prompt, once per 4-hour window |
| `auto-handoff` | Session end | Appends timestamped snapshot: modified files, commits, active tickets |

> The agent wakes up knowing where things stand. You say nothing about context.

Works across Claude Code, Codex, and Pi — all three read and write the same `HANDOFF.md`.

---

# Layer 2 — Knowledge capture

**Pain:** Non-obvious constraints found mid-session vanish when context compacts or the session ends.

**Solution:** `capture` writes discoveries immediately to `HANDOFF.md ## Discoveries` — not at wrapup, not at session end.

**What qualifies:**
- Filter/exclusion rules found through experimentation
- Numerical facts not in code (row counts, limits, offsets)
- Environment gotchas (args, paths, build quirks)
- Architecture decisions with non-obvious WHY
- Any constraint found through investigation not visible in the code

**Automatic** — fires whenever the agent encounters something qualifying.

**Manual override:**

| Agent | Trigger |
|---|---|
| Claude Code | `/capture <text>` |
| Codex / Pi | "Capture this" / "Record this in discoveries" |

---

# Layer 3 — Code quality

Three passes, in order, with smart skip logic:

## code-simplifier
Clarity and redundancy pass — reduces nesting, eliminates dead code, improves names.
*Never changes behavior.*

## code-reviewer
Seven dimensions: correctness, maintainability, readability, efficiency, security, edge cases, test coverage.
Reports: Critical / Improvements / Nitpicks / Recommendations.

## security-review
High-confidence vulnerability scan — traces data flow end-to-end before flagging.
Only reports what's confirmed exploitable. No noisy pattern-match output.

| Step | Skipped when |
|---|---|
| code-simplifier | Single-line change, or docs/config only |
| code-reviewer | Single-line fix, no design implications |
| security-review | No auth, DB, user input, API, crypto, or file I/O changed |

---

# A complete session

| Who | What |
|---|---|
| *hook* | `handoff-inject` reads `HANDOFF.md` silently — agent knows the state |
| **You** | "Sprint start — add rate limiting to login endpoint" |
| *agent* | Creates ticket `t-r4t3`, blueprint, acceptance criteria, reads DECISIONS.md |
| *orient* | Maps auth/, login code, middleware — flags admin shortcut path as non-obvious caller |
| *agent* | Grills gray areas. Rates impact. Produces sprint brief. Waits. |
| **You** | "Yes" |
| *agent* | Writes code. Reads Redis config. |
| *capture* | Auto-fires: "Redis pool capped at 5 — rate checks may queue. `config/redis.py:12`" |
| **You** | "Sprint complete" |
| *wrapup* | Simplifies middleware. Reviewer flags missing bypass test. |
| *agent* | Stops. Writes bypass test. All criteria ✓. |
| *agent* | Appends to DECISIONS.md. Proposes convention for AGENTS.md — you confirm. Closes ticket. |
| **You** | Close Claude Code |
| *hook* | `auto-handoff` snapshots git state to HANDOFF.md |

Next session — or next agent — picks up exactly here.

---

# Setup — two steps

**1. Clone canon (once)**
```bash
git clone https://github.com/sunitghub/canon.git ~/Developer/canon
```

**2. Run init (once)**
```bash
cd ~/Developer/canon && ./skills.sh init
```

Configures Claude Code, Codex, and Pi — skips any not installed. Safe to re-run.
Ends by printing available commands so you know what to do next.

**Then — register skills per project**
```bash
cd /path/to/your-project
~/Developer/canon/skills.sh addall   # or: skills add sprint
```

**Optional — RTK** (token optimizer, 60–90% savings on CLI output):
```bash
brew install rtk   # install before running init so it gets wired automatically
```

---

# Benefits at a glance

| Without canon | With canon |
|---|---|
| Re-explain context every session | Agent reads `HANDOFF.md` on open — no re-explaining |
| Discoveries vanish when context fills | `capture` writes them instantly, survives compaction |
| Quality steps skipped or out-of-order | `wrapup` runs them automatically, in sequence |
| Ship without a definition of done | `acceptance.md` gates `sprint complete` |
| Architectural decisions forgotten | `DECISIONS.md` read at sprint start, written at close |
| Agent edits blind in unfamiliar code | `orient` maps the subsystem before any file is touched |
| Conventions trapped in one engineer's head | Sprint close proposes AGENTS.md updates while context is fresh |
| Agent switches lose context | All agents share the same `HANDOFF.md` |

---

# Render this deck

```bash
# Option 1 — pandoc with Octave theme (run from canon root)
printf '<style>' > /tmp/octave-hdr.html \
  && cat guides/octave-theme.css >> /tmp/octave-hdr.html \
  && printf '</style>' >> /tmp/octave-hdr.html && \
pandoc guides/AI-Agents-Deck.md \
  -t revealjs -s --slide-level=1 \
  -V theme=black -V transition=fade \
  -V width=1280 -V height=720 \
  -V pagetitle="Canon — AI Agent Skills Library" \
  -H /tmp/octave-hdr.html \
  -o guides/AI-Agents-Deck.html

# Option 2 — mise (no permanent node install)
mise x npm:@marp-team/marp-cli@latest -- marp guides/AI-Agents-Deck.md --pdf
mise x npm:@marp-team/marp-cli@latest -- marp guides/AI-Agents-Deck.md --pptx

# Option 3 — VS Code extension
# Install "Marp for VS Code", open this file, click Preview
```
