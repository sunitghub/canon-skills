# Context Optimization

AI agents are stateless by default. Without deliberate management:
- Every session starts cold — re-explaining takes 10+ minutes and burns tokens
- CLI commands dump raw verbose output — each `git log` or `gh api` call can cost thousands of tokens
- Code quality erodes silently — no automatic quality gate between "task done" and "commit"

This repo addresses all three with two mechanisms at different layers.

---

## Layer 1 — Context Persistence (Handoff)

**What:** `HANDOFF.md` in the repo root is a shared snapshot of working state — current focus, in-progress files, recent decisions, next steps. Any agent that reads it picks up where the last one left off.

**Two hooks make this automatic in Claude Code:**

| Hook | Script | Fires when | What it does |
|---|---|---|---|
| `Stop` | `auto-handoff.sh` | Claude finishes a turn with uncommitted changes | Appends a timestamped git-state snapshot to `HANDOFF.md`, commits it if `HANDOFF.md` is tracked by git |
| `UserPromptSubmit` | `handoff-inject.sh` | First message of each session (4h window) | Injects `HANDOFF.md` into Claude's context |

**FIFO snapshot window:** The Stop hook appends the newest snapshot and keeps only the last 2, so the next agent can see current state and prior state without `HANDOFF.md` growing indefinitely.

**Manual fallback (any agent):** Say "wrap up" — the agent writes `HANDOFF.md` and commits it. Works in Claude, Codex, and Pi.

**Keep HANDOFF.md under 80 lines.** The inject hook warns when it grows beyond this. Prune stale entries freely — the git history preserves everything.

---

## Layer 2 — Quality Automation (Hooks + Wrapup)

**What:** A sequence of hooks enforces a quality gate between "task done" and "commit" without requiring any user prompting.

**Hook execution order in a typical workflow:**

```
User sends message
  └─ UserPromptSubmit → handoff-inject.sh   (inject HANDOFF.md once per session)

Claude runs: git commit
  └─ PreToolUse[Bash] → pre-commit-check.sh  (remind: close tickets, run /wrapup)

Claude runs: sprint complete
  └─ sprint validates acceptance and runs wrapup before closing the active ticket

/wrapup runs
  └─ code-simplifier → code-reviewer → security-review → repo-check → doc-audit
     (skip logic per change scope)

Claude finishes turn
  └─ Stop → auto-handoff.sh  (snapshot git state to HANDOFF.md if changes exist)
```

**Wrapup skip logic:** Not every change needs every step. Wrapup self-directs:
- Skip `code-simplifier` for single-line changes, docs-only, or config-only diffs
- Skip `code-reviewer` for purely mechanical changes (rename, format, move)
- Skip `security-review` if no security-sensitive files changed (auth, DB, user input, API, crypto)

When a step is skipped, Wrapup states why — so it's clear the step was considered, not missed.

**Registering the quality pipeline in a project:**
```bash
skills.sh add sprint /path/to/project
```
`sprint` includes wrapup and its full dependency stack automatically — `code-simplifier`, `code-reviewer`, `security-review`, `repo-check`, `doc-audit`, `handoff`, and `ticket`. Directly registering `wrapup` is only useful for advanced/manual workflows that intentionally do not use sprint tickets.

---

## Input vs Output Tokens

Understanding which side of the budget is larger shapes where to optimize.

**In agentic/coding workflows, input dominates — by a large margin:**

- **Context window accumulates** — every prior turn, tool result, and system prompt is re-sent as input on the next turn. Turn 50 carries all 49 prior turns.
- **Tool results are the biggest driver** — a single `git log` or `gh api` call can return thousands of tokens of raw text, all landing as input. Prefer targeted commands (`git log --oneline -5`) over broad ones.
- **System prompts re-send every turn** — the full CLAUDE.md chain (AGENTS.md + loaded skills + standards) is injected as input on every message.

Output is comparatively small: responses are terse, tool calls are compact JSON.

**Where output matters:**
- Long-form generation (writing docs, generating large files)
- Pricing math: output tokens cost ~5x more than input on Claude models (Sonnet 4.6: $3/M input, $15/M output) — a smaller output volume can still have outsized cost impact at scale

**What this means for each layer in this repo:**

| Layer | Targets | Type |
|---|---|---|
| Handoff | Growing context window (session re-explanation) | Input |
| Prompt caching | Repeated system prompts (CLAUDE.md chain) | Input |
| Terse response style (AGENTS.md) | Claude's replies | Output |

**Rule of thumb:** In agentic workflows, optimize input first (HANDOFF.md pruning, targeted commands, prompt caching). Output optimization matters at scale or when generating large artifacts.

---

## How the layers interact

```
Token budget
  ├── Handoff keeps session context tight (prune to <80 lines)
  └── Wrapup catches quality issues before they accumulate in the codebase

Context window
  ├── handoff-inject.sh: ~200–400 tokens once per 4h (net positive — avoids re-explaining)
  └── auto-handoff.sh: zero token cost (runs after Claude stops)
```

The goal is that a new session in any agent — Claude, Codex, Pi — costs less than 500 tokens to get fully oriented, with no manual re-explaining.
