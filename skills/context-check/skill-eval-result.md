## Skill Eval: context-check
Run: 2026-11-15

### Structural check
Body: pass — body within threshold (72 lines; threshold: 500 — standalone)
Evals: pass — 9 eval cases

### Case 1: Run a context check. Assume ~/.claude/CLAUDE.md has two @-i...
- "Produces a size table with file names and line counts" → pass
  Evidence: "| AGENTS.md (@-import) | 80 | — |" and "| standards/efficiency.md (@-import) | 120 | Y |"
- "States that line counts are a proxy for context weight, not exact token counts" → pass
  Evidence: "Line counts are a proxy for context weight, not exact token counts."
- "Lists sprint and wrapup as project-local skills with their sizes" → pass
  Evidence: "Project-local: `sprint` (SKILL.md, 450 lines), `wrapup` (SKILL.md, 90 lines)."
- "Flags high-line-count files where less than half is usually relevant" → pass
  Evidence: "80 of them (two-thirds) are the one-time `## Migrating from the 2025 layout` section"
- "Asks 'Write context-check-report.md report? (y to confirm)' before writing anything" → pass
  Evidence: ends with the prompt; "Nothing was written"

### Case 2: Run a context check. ~/.claude/CLAUDE.md imports two files....
- "Identifies and reports the cross-file redundancy with quotes from both files" → pass
  Evidence: quotes `- No sycophantic openers or closing fluff.` / `- Short responses by default.` from both files
- "Asks 'Write context-check-report.md report? (y to confirm)' before writing" → pass
  Evidence: output ends with the prompt; nothing written before it
- "Does not write context-check-report.md or .reports/context-check-history.json without confirmation" → pass
  Evidence: "no report was written and the history file was not touched"

### Case 3: Run a context check. A context-check-report.md from an earl...
- "Reports the 'Short responses by default.' redundancy between AGENTS.md and standards/efficiency.md as a current finding" → pass
  Evidence: "Finding: Cross-file redundancy ... "- Short responses by default.""
- "Does not skip or suppress the finding because the earlier report or the leftover context-findings.md already lists it" → pass
  Evidence: "`context-findings.md` at the project root is not read and not used"
- "Asks 'Write context-check-report.md report? (y to confirm)' before writing" → pass
  Evidence: "Step 9 prompt (verbatim) ... Write context-check-report.md report? (y to confirm)"
- "States or implies that the report would be overwritten, not appended to" → pass
  Evidence: "The new report would overwrite the old one"

### Case 4: Run a context check. There is no .claude/skills/ directory...
- "Notes 'No `.claude/skills/` directory found' (or the same words) and continues" → pass
  Evidence: Step 2 prints the note, run moves on to step 3
- "Reports missing ~/.claude/CLAUDE.md without stopping" → pass
  Evidence: "`~/.claude/CLAUDE.md` is absent ... Continued."
- "Reports missing ~/.claude/settings.json without stopping" → pass
  Evidence: "`~/.claude/settings.json` is absent ... Continued."
- "Reports missing memory paths without stopping" → pass
  Evidence: "No `~/.claude/projects/*/memory/` paths exist." Continued.
- "Continues with the project artifact checks" → pass
  Evidence: "No project-level .claude/ artifacts found."
- "Does not error or stop because optional global artifacts are missing" → pass
  Evidence: stops only at step 8's no-findings rule

### Case 5: Run a context check. ~/.claude/CLAUDE.md imports two files....
- "Explicitly states no relevance concern (or equivalent) for AGENTS.md" → pass
  Evidence: "`AGENTS.md`: no relevance concern (18 lines, under 30 ...)"
- "Explicitly states no relevance concern (or equivalent) for standards/git.md" → pass
  Evidence: "`standards/git.md`: no relevance concern (14 lines, under 30)."
- "Does not silently omit the per-file verdict for clean files" → pass
  Evidence: verdict per file in the table and the bullets
- "Stops before the write prompt: does not ask to write the report and writes no file" → pass
  Evidence: "Stopping before the write prompt; no report written."

### Case 6: Run a context check for the project at /work/app. ~/.claude...
- "Asks 'Write context-check-report.md report? (y to confirm)' and writes only after the 'y'" → pass
  Evidence: prompt verbatim, then "The user answers `y`", then both writes
- "context-check-report.md is a markdown table with the header | File | Status | Details |" → pass
  Evidence: report begins "| File | Status | Details |"
- "Every Status cell is exactly one of: clean, issues found, not present, skipped" → pass
  Evidence: all 8 rows use clean, issues found or not present
- "AGENTS.md is 'issues found' and .claude/settings.local.json is 'not present'" → pass
  Evidence: "| ~/.claude/AGENTS.md | issues found | ..." and "| .claude/settings.local.json | not present | — |"
- "The report has no '**Trend:**' line, because there is no earlier history entry" → pass
  Evidence: "It has no Trend line because there was no prior entry."
- ".reports/context-check-history.json holds one entry under the key /work/app with a timestamp, finding_count 1 and a file_count equal to the report's row count" → pass
  Evidence: "/work/app": [{timestamp, "finding_count": 1, "file_count": 8}]; 8 report rows

### Case 7: Run a context check for the project at /work/app. .reports/...
- "Asks 'Write context-check-report.md report? (y to confirm)' and writes only after the 'y'" → pass
  Evidence: prompt verbatim, then the history read and report write
- "The report's first line is '**Trend:** findings 3 → 1 (last run 2026-11-01T09:00:00Z)', above the table" → pass
  Evidence: "the exact first line ...: `**Trend:** findings 3 → 1 (last run 2026-11-01T09:00:00Z)`"
- "The /work/app array still holds exactly 20 entries after the write" → pass
  Evidence: "That made 21 entries, so I dropped the front entry ... It now has exactly 20 entries"
- "The dropped entry is the oldest one (2026-01-05T09:00:00Z) and the new entry is last, with finding_count 1" → pass
  Evidence: "dropped the front entry (timestamp 2026-01-05T09:00:00Z) ... the new entry is last"
- "The /work/other key and its 2 entries are not changed" → pass
  Evidence: "Key "/work/other": unchanged, still 2 entries."

### Case 8: Run a context check. ~/.claude/CLAUDE.md imports one file, ...
- "Includes file name and line count as evidence for the size finding" → pass
  Evidence: "`docs/team-guide.md` (90 lines): size issue."
- "Explains why the flagged content is rarely needed or one-time" → pass
  Evidence: "one-time onboarding section that is used only during project setup"
- "Asks 'Write context-check-report.md report? (y to confirm)' before writing" → pass
  Evidence: prompt printed, then "`context-check-report.md` not written"

### Case 9: Run a context check. .claude/skills/ contains: `sprint`, a w...
- "Lists sprint under canon-managed with the target /Users/dev/.canon/skills/sprint, and does not audit its content" → pass
  Evidence: "Canon-managed: `sprint` → `/Users/dev/.canon/skills/sprint` (content not audited)"
- "Lists deploy under project-local with its size, and audits its content" → pass
  Evidence: "Project-local: `deploy` → `SKILL.md`, 40 lines"; dead reference found on read
- "Asks 'Write context-check-report.md report? (y to confirm)' and writes only after the 'y'" → pass
  Evidence: prompt verbatim, "The user answered `y`", then the write
- "The report's sprint row has Status 'skipped' and names /Users/dev/.canon/skills/sprint in Details" → pass
  Evidence: "| .claude/skills/sprint | skipped | /Users/dev/.canon/skills/sprint |"
- "The report's deploy row has Status 'issues found'" → pass
  Evidence: "| .claude/skills/deploy/SKILL.md | issues found | Dead reference ... |"

### Summary
41/41 expectations passed
Verdict: pass
Executors and graders: claude-opus-5-5. Cases 1, 3, 5 and 8 were revised once after a first run (case 1 gave no file text, so no finding could reach the write prompt; case 3 did not separate the old skill from the new; case 5's "clean" file held two arguable obvious/vague lines; case 8 named no file) and these results are from the re-run. Baseline: revised case 3 against the pre-change SKILL.md skips the redundancy (it reads context-findings.md) and stops with no findings, so the case fails there. Case 9 passes on the pre-change skill too: it adds coverage, not a regression check.

### Issues
| Issue | Details | Reason |
|---|---|---|
| file_count is ambiguous | Executors differed on whether `not present` rows and absent directories (memory, `.claude/skills/`) count as report rows, so file_count ranged 5-9 for similar states | The Trend line compares finding_count only, so no graded output changed; a future case on file_count would be flaky |
| Imported AGENTS.md vs repo AGENTS.md | Step 7 reads "repo `AGENTS.md`" separately from the `@` imports; executors treated an imported AGENTS.md as one file and placed it under Global, without guidance | Ambiguity, no graded failure |
