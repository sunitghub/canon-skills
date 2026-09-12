---
name: bulk-read
description: Size-gated citation-only reading for large files — checks line count, reads directly under the threshold, dispatches a fresh-context Haiku subagent that returns only file:line citations over it. Use when exploring/understanding a large file (not editing it) in any sprint tier, not just high-risk orient research.
category: agent-ops
tags: [context, tokens, efficiency, subagent, cross-platform]
---

# Bulk Read

Portable, advisory alternative to a hard read-size block. Canon installs zero Claude Code hooks —
see Gotchas — so this skill cannot mechanically prevent a large direct `Read` the way a
`PreToolUse` hook could. It generalizes `skills/sprint/reference/orient.md`'s citation-only
subagent pattern into a single-file primitive usable from any tier, not just high-risk orient.

## When to use

You're about to read a file to **understand or research** it — trace a caller, learn a pattern,
answer "what does X do" — and the file might be large. Not for a file you are about to **edit**:
`Edit` needs the real, direct `Read`; editing and reasoning are not delegable to a subagent that
never actually holds the content.

## Steps

1. **Check size.** `wc -l <file>` — plain POSIX, works identically in macOS Terminal and Windows
   Git Bash. No GNU-only flags, no PowerShell, no `uuidgen`-class Windows pitfalls.
2. **Under 300 lines (default threshold, adjustable):** just `Read` it directly. Delegation has a
   real round-trip cost (dispatch + subagent turnaround); routing a small file wastes more than it
   saves — mirrors the same tradeoff `skills/sprint/reference/orient.md`'s own dispatch step
   accepts for small subsystems.
3. **300+ lines, exploratory read:** dispatch one fresh-context subagent (`Agent` tool,
   `model: haiku` — same tier as `explore` in `AGENTS.md`'s Model Tiers) with:
   - The file path (forward slashes — never a Windows-style backslash path in the prompt).
   - The specific question you need answered (not "summarize this file" — a targeted question
     keeps the subagent's own read purposeful and its citations relevant).
   - Instruction: read the file, answer the question, and cite every claim as
     `file:line — \`quoted text\`` — the same citation contract `orient.md` already uses. Return
     text only; do not write files.
4. **Use only the subagent's returned citations.** Never ask the subagent to paste back raw file
   content, and never follow up by reading the file yourself unless its answer is insufficient —
   that would defeat the entire point.

## What this does and doesn't guarantee

This is **advisory instruction, not mechanical enforcement**. Nothing stops a direct `Read` of a
900-line file if you (or a future session) skip this skill — there is no hook blocking that call.
This is a deliberate tradeoff, not an oversight: canon installs zero Claude Code hooks, an
incident-driven, repeatedly-reaffirmed decision (`DECISIONS.md` — hooks removed after none proved
load-bearing, one destroyed a user's `settings.json`; a later hook-based design was explicitly
rejected for colliding with this rule). A `PreToolUse` size-gate hook would also be Claude-Code-only
— silently absent under Codex — which conflicts with canon's cross-harness portability goal more
than the advisory gap here does. If canon's zero-hooks stance changes, revisit this tradeoff; until
then, this skill is the portable alternative, not a guarantee.

## Gotchas

- **Codex per-agent model selection is unconfirmed.** The Haiku dispatch in step 3 is confirmed
  working under Claude Code. Codex's `spawn_agent` has no `model` field — its model picker is
  session-level — so don't assume the cost savings hold there without testing live first (same
  caveat `AGENTS.md`'s Model Tiers section already carries for `explore`).
- **A vague question produces a vague citation set.** If the subagent's answer doesn't actually
  resolve what you needed, that's a sign the question was under-specified, not that this skill
  failed — re-dispatch with a sharper question rather than falling back to a direct `Read`.
- **300 is a default, not a law.** Adjust up or down for a specific file/task if you have a
  concrete reason (e.g. a 280-line file that's mostly boilerplate imports is fine to read directly;
  a dense 250-line file might be worth routing anyway). Don't treat the number as load-bearing
  precision.
