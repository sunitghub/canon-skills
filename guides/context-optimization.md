# Context Optimization

AI agents are stateless by default. Without deliberate management:
- Every session starts cold — re-explaining takes 10+ minutes and burns tokens
- CLI commands dump raw verbose output — each `git log` or `gh api` call can cost thousands of tokens
- Code quality erodes silently — no automatic quality gate between "task done" and "commit"

This repo addresses all three with three mechanisms at different layers.

---

## Layer 1 — Token Compression (RTK)

**What:** RTK intercepts CLI commands and filters verbose output before it reaches the token budget. A `git log --oneline -20` that would produce 3K tokens of raw text becomes a compact summary.

**Claude Code:** Fully automatic. The `PreToolUse[Bash]` hook in `~/.claude/settings.json` rewrites every command transparently — `git status` becomes `rtk git status` before it runs. Set up via:
```bash
rtk init -g --auto-patch   # installs hook into ~/.claude/settings.json
```

**Codex:** No hook equivalent — Codex has no `PreToolUse` lifecycle. Instead, RTK injects instructions into `~/.codex/AGENTS.md` so Codex knows to prefix commands manually. Set up via:
```bash
rtk init -g --codex --auto-patch   # writes ~/.codex/RTK.md + adds @reference in ~/.codex/AGENTS.md
```
Codex reads `RTK.md` on every session and applies the `rtk` prefix itself. Less reliable than a hook (instruction-following vs. automatic rewrite) but functional.

**Other agents:** Cursor, Windsurf, Cline, Gemini CLI, and others have their own init flags — see `rtk init --help`. All non-hook agents work the same way as Codex: instruction injection, manual prefix required.

**Coverage boundary:** RTK only intercepts `Bash` tool calls. Claude Code's native tools (`Read`, `Grep`, `Glob`) bypass the hook entirely — their output lands unfiltered in the context window. To get RTK filtering for file reads and searches, use shell commands (`cat`, `grep`, `find`) rather than native tools.

**Check coverage:**
```bash
rtk gain              # token savings to date
rtk gain --history    # per-command breakdown
rtk discover          # commands that slipped through without RTK
```

**Covered commands:** `git`, `gh`, `grep`, `find`, `ls`, `cat`/`read`, `brew`, `cargo`, `npm`, and more. If RTK has no rule for a command, it passes through unchanged.

---

## Layer 2 — Context Persistence (Handoff)

**What:** `HANDOFF.md` in the repo root is a shared snapshot of working state — current focus, in-progress files, recent decisions, next steps. Any agent that reads it picks up where the last one left off.

**Two hooks make this automatic in Claude Code:**

| Hook | Script | Fires when | What it does |
|---|---|---|---|
| `Stop` | `auto-handoff.sh` | Claude finishes a turn with uncommitted changes | Appends a timestamped git-state snapshot to `HANDOFF.md`, commits it |
| `UserPromptSubmit` | `handoff-inject.sh` | First message of each session (4h window) | Injects `HANDOFF.md` into Claude's context via `rtk read` |

**LIFO snapshot window:** The Stop hook keeps the last 2 snapshots — current state and prior state — so the next agent can see both where things stand now and where they were. Older snapshots are pruned automatically.

**Manual fallback (any agent):** Say "wrap up" — the agent writes `HANDOFF.md` and commits it. Works in Claude, Codex, and Pi.

**Keep HANDOFF.md under 80 lines.** The inject hook warns when it grows beyond this. Prune stale entries freely — the git history preserves everything.

---

## Layer 3 — Quality Automation (Hooks + Polish)

**What:** A sequence of hooks enforces a quality gate between "task done" and "commit" without requiring any user prompting.

**Hook execution order in a typical workflow:**

```
User sends message
  └─ UserPromptSubmit → handoff-inject.sh   (inject HANDOFF.md once per session)

Claude runs: git commit
  └─ PreToolUse[Bash] → rtk hook claude        (rewrite for token efficiency)
                      → pre-commit-check.sh  (remind: close tickets, run /polish)

Claude runs: tk close <id>
  └─ PostToolUse[Bash] → auto-polish-trigger.sh  (instruct Claude: run /polish now)

/polish runs
  └─ code-simplifier → code-reviewer → security-review  (skip logic per change scope)

Claude finishes turn
  └─ Stop → auto-handoff.sh  (snapshot git state to HANDOFF.md if changes exist)
```

**Polish skip logic:** Not every change needs all three steps. Polish self-directs:
- Skip `code-simplifier` for single-line changes, docs-only, or config-only diffs
- Skip `code-reviewer` for purely mechanical changes (rename, format, move)
- Skip `security-review` if no security-sensitive files changed (auth, DB, user input, API, crypto)

When a step is skipped, Polish states why — so it's clear the step was considered, not missed.

**Registering polish in a project:**
```bash
for s in code-simplifier code-reviewer security-review polish; do
  ~/Developer/AI-Skills/skills.sh add $s /path/to/project
done
```
The `auto-polish-trigger.sh` and `pre-commit-check.sh` hooks check whether polish is registered before firing — they stay silent in projects where it isn't.

---

## Input vs Output Tokens

Understanding which side of the budget is larger shapes where to optimize.

**In agentic/coding workflows, input dominates — by a large margin:**

- **Context window accumulates** — every prior turn, tool result, and system prompt is re-sent as input on the next turn. Turn 50 carries all 49 prior turns.
- **Tool results are the biggest driver** — a single `git log` or `gh api` call can return thousands of tokens of raw text, all landing as input. This is what RTK targets.
- **System prompts re-send every turn** — the full CLAUDE.md chain (AGENTS.md + loaded skills + standards) is injected as input on every message.

Output is comparatively small: responses are terse, tool calls are compact JSON.

**From real usage in this repo:** RTK saved 2.1M tokens at 95% efficiency — entirely input savings from CLI output being filtered before it enters the context window.

**Where output matters:**
- Long-form generation (writing docs, generating large files)
- Pricing math: output tokens cost ~5x more than input on Claude models (Sonnet 4.6: $3/M input, $15/M output) — a smaller output volume can still have outsized cost impact at scale

**What this means for each layer in this repo:**

| Layer | Targets | Type |
|---|---|---|
| RTK | CLI tool results (verbose command output) | Input |
| Handoff | Growing context window (session re-explanation) | Input |
| Prompt caching | Repeated system prompts (CLAUDE.md chain) | Input |
| Terse response style (AGENTS.md) | Claude's replies | Output |

**Rule of thumb:** In agentic workflows, optimize input first (RTK, HANDOFF.md pruning, prompt caching). Output optimization matters at scale or when generating large artifacts.

---

## How the layers interact

```
Token budget
  ├── RTK compresses CLI output (saves ~95% on covered commands)
  ├── Handoff keeps session context tight (prune to <80 lines)
  └── Polish catches quality issues before they accumulate in the codebase

Context window
  ├── handoff-inject.sh: ~200–400 tokens once per 4h (net positive — avoids re-explaining)
  ├── RTK read on HANDOFF.md: further reduces inject cost
  └── auto-handoff.sh: zero token cost (runs after Claude stops)
```

The goal is that a new session in any agent — Claude, Codex, Pi — costs less than 500 tokens to get fully oriented, with no manual re-explaining.
