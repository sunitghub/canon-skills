---
name: context-check
description: Audit always-on context load for bloat, redundancy, and quality — invoke periodically or when context feels heavy
category: agent-ops
tags: [context, tokens, efficiency, audit]
---

# Context Check

Audit what Claude loads every session. Append to `context-findings.md` (project root) only after explicit confirmation.

## Steps

1. Read `context-findings.md` if it exists; skip logged issues.

2. Read `~/.claude/CLAUDE.md`. For each `@` import, count lines and produce:
   | File | Lines |
   |------|-------|

3. Run `skills.sh status` if `skills.sh` is on PATH; otherwise try `./tools/skills.sh status` if that file exists. List registered skills and file sizes. If neither is available, skip.

4. Read `~/.claude/settings.json`; list hooks, matchers, and scripts.

5. List `~/.claude/projects/*/memory/`; report file count and total size.

6. Flag size issues where line count > 30 and less than half is usually relevant, or a section is one-time/rarely needed.

7. Read each imported file plus repo `AGENTS.md`. Flag only high-confidence issues:

   - **Cross-file redundancy** — the same rule or constraint appears in two or more files, verbatim or near-verbatim. Quote both occurrences.
   - **Obvious statements** — rules a capable model already follows.
   - **Vague non-actionable rules** — instructions with no specific compliance path.
   - **Dead references** — paths, tools, or commands that no longer exist. Verify before flagging.

   Report content findings separately from size findings.

8. Report the size table, then content findings. If none: say so and stop.

9. If findings exist, ask: `Append these to context-findings.md? (y to confirm)`. Do not write without `y`. Write to `context-findings.md` at the project root.

## context-findings.md entry format

```
### YYYY-MM-DD — Short title
**File:** path
**Issue:** what was found
**Action:** what was done (or "Open — no action yet")
```

Keep entries concise. When the file exceeds 60 lines, archive (delete) entries older than 6 months before appending.
