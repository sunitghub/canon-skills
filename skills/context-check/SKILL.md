---
name: context-check
description: Audits always-on context load for bloat, redundancy, and quality. Use when context feels heavy or periodically to keep the always-on budget lean.
category: agent-ops
tags: [context, tokens, efficiency, audit]
---

# Context Check

Audit what Claude loads every session. Writes `context-check-report.md` at the project root after explicit confirmation.

## Steps

1. Read `context-findings.md` if it exists; skip logged issues.

2. **Global artifacts** — check `~/.claude/CLAUDE.md`. If it is absent, say so and continue. If present, read it. For each `@` import, count lines and produce a size table:
   | File | Lines | Issues |
   |------|-------|--------|

3. Check `.claude/skills/` in the current working directory.

   If the directory doesn't exist, note "No `.claude/skills/` directory found" and continue.

   If it exists:
   - Run `./tools/skills.sh status` if that file exists, otherwise `skills.sh status` if on PATH. This gives the full registered-skill list.
   - Run `find .claude/skills -maxdepth 1 -mindepth 1 -type l 2>/dev/null` to identify whole-dir symlinks (canon-managed, classic model).
   - Run `find .claude/skills -maxdepth 1 -mindepth 1 \! -type l -type d 2>/dev/null` to identify real subdirectories. For each, run `readlink .claude/skills/<name>/SKILL.md 2>/dev/null` — if the target contains `/canon/skills/` or `/.canon/skills/`, it is canon-managed (per-skill model); otherwise it is project-local.

   Report two sub-lists:
   - **Canon-managed** (whole-dir symlinks, or real dirs whose SKILL.md symlinks to a canon path): name and symlink target only. Do not audit content — these are installed from an external source and not part of the project's own context footprint.
   - **Project-local** (real dirs with no canon SKILL.md symlink): name and file size. Include in the content audit at step 8.

4. Check `~/.claude/settings.json`. If it is absent, say so and continue. If present, read it and list hooks, matchers, and scripts.

5. Find the current repo's Claude project memory first, if present, then summarize other `~/.claude/projects/*/memory/` directories. If no memory paths exist, say so and continue. Report file count and total size; use line counts or bytes as a proxy, not exact tokens.

6. **Project artifacts** — check the following in the current working directory. For each: report lines if present, or "not present" if absent.
   - `.claude/settings.json`
   - `.claude/settings.local.json`
   - `CLAUDE.md` (project root)

   Produce a project-level size table (omit rows for absent files):
   | File | Lines | Issues |
   |------|-------|--------|

   If none exist, state "No project-level .claude/ artifacts found."

7. Flag size issues where line count > 30 and less than half is usually relevant, or a section is one-time/rarely needed. Include the evidence: file, line count, and a short reason the content is usually irrelevant or rarely needed.

8. Read each imported file plus repo `AGENTS.md`, and each present project artifact from Step 6. Skip canon-managed skills identified in Step 3 (symlinked skill dirs or @-imports that resolve to a canon install path such as `~/.canon/`, `~/.claude/skills/`, or any path containing `/canon/skills/`). Flag only high-confidence issues in project-owned files:

   - **Cross-file redundancy** — the same rule or constraint appears in two or more files, verbatim or near-verbatim. Quote both occurrences.
   - **Obvious statements** — rules a capable model already follows. Quote the statement and explain why it adds little control.
   - **Vague non-actionable rules** — instructions with no specific compliance path. Quote the rule and explain what is not enforceable.
   - **Dead references** — paths, tools, or commands that no longer exist. Verify before flagging and name the failed check.

9. Report in two labeled sections:

   **### Global** — size table from Steps 2–5, content findings for global files.

   **### Project** — size table from Step 6, content findings for project-level files.

   Note below each size table: "Line counts are a proxy for context weight, not exact token counts."

   In each size table, set the **Issues** column to `Y` if any finding was flagged for that file, `—` if none. For each file assessed in Steps 7–8, explicitly state either the issue found or "no relevance concern" — do not silently skip files that passed. If one section has no findings, say so and continue to the next section. If no findings exist anywhere, stop before the write prompt.

10. Ask: `Write context-check-report.md report? (y to confirm)`. Do not write without `y`. On confirmation, write `context-check-report.md` at the project root as a markdown table:

   ```
   | File | Status | Details |
   |------|--------|---------|
   ```

   One row per audited file. **Status** must be exactly one of: `clean`, `issues found`, `not present`, `skipped`. Use `skipped` for canon-managed files that are not audited. **Details** is a one-line summary of the finding or reason, or `—` if none. Overwrite if the file already exists — this is a point-in-time snapshot, not a log.
