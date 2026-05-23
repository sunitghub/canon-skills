---
name: context-findings
description: Running evidence log of context efficiency findings — bloat identified, optimizations made, open items.
category: agent-ops
tags: [context, tokens, efficiency]
hidden: true
---

# Context Findings

Evidence log for context efficiency. Paired with `standards/efficiency.md` (rules) — this file is the observations.

Run `/context-check` to generate new findings. Append only on explicit confirmation.

---

### 2026-05-23 — RTK.md installation verification block
**File:** `~/.claude/RTK.md`
**Issue:** "Installation Verification" section (`rtk --version`, `which rtk`) is debug tooling, irrelevant during normal work. Loaded every session.
**Action:** Removed section.

### 2026-05-23 — PostToolUse gap on Edit/Write
**File:** `~/.claude/settings.json`
**Issue:** PostToolUse hook only matched `Bash`. No feedback when managed files (e.g., `CATALOG.md`) were edited directly.
**Action:** Added `guard-managed-files.sh` as `PostToolUse[Edit|Write]` hook.
