## Skill Eval: context-check
Run: 2026-06-22

### Structural check
Body: pass — body within threshold (61 lines; threshold: 500 — standalone)
Evals: pass — 7 eval cases

### Case 1: Run a context check. Assume ~/.claude/CLAUDE.md has t...
- "Produces a size table with file names and line counts" → partial
  Evidence: Table present but used acknowledged assumed values (450-line sprint) rather than measured values; real values noted as afterthought.
- "States that line counts are a proxy for context weight, not exact token counts" → fail
  Evidence: Executor's own note confirmed this was not stated in output, despite being present in Step 2 instructions.
- "Lists registered skills and their sizes" → partial
  Evidence: Skills listed with assumed sizes acknowledged as fabricated; real measurements presented separately rather than as primary output.
- "Flags high-line-count files where less than half is usually relevant" → partial
  Evidence: Files flagged Y in issues column but criterion (more than half rarely relevant) not consistently applied — flags for AGENTS.md/efficiency.md were for other issues.
- "Asks for confirmation before writing to context-findings.md" → pass
  Evidence: "Append these to context-findings.md? (y to confirm)" present at end of output.

### Case 2: Run a context check. No context-findings.md exists. ~/.cl...
- "Identifies and reports the cross-file redundancy with quotes from both files" → pass
  Evidence: Quoted identical Output Style block from both AGENTS.md and efficiency.md verbatim.
- "Asks 'Append these to context-findings.md? (y to confirm)' before writing" → pass
  Evidence: Exact phrase present at end of output before any write action.
- "Does not write to context-findings.md without confirmation" → pass
  Evidence: Executor explicitly states "No write was performed."

### Case 3: Run a context check. context-findings.md already contains...
- "Skips the already-logged issue from context-findings.md" → pass
  Evidence: Identified 2026-06-10 entry and used it to orient what not to re-flag.
- "Reports no new findings" → partial
  Evidence: Spotted Agent Design duplication but self-suppressed it citing eval spec framing ("task instructs you find no new issues") — contaminated by spec awareness rather than genuine absence of findings.
- "Does not write to context-findings.md" → pass
  Evidence: No write performed, no append prompt issued.
- "Stops after reporting no new issues" → pass
  Evidence: Step 10 confirms skill halted before append prompt.

### Case 4: Run a context check. skills.sh is not on PATH and ./tools/...
- "Skips skills.sh check and explicitly notes it is unavailable" → pass
  Evidence: "confirmed unavailable per task conditions" stated in Step 3.
- "Reports missing ~/.claude/CLAUDE.md without stopping" → fail
  Evidence: Executor reported CLAUDE.md as "present (5 lines)" and read it from the real filesystem; task specifies it is absent.
- "Reports missing ~/.claude/settings.json without stopping" → pass
  Evidence: Step 4 reports "absent" and continues.
- "Reports missing memory paths without stopping" → pass
  Evidence: Step 5 reports "none present" and continues.
- "Continues with remaining audit steps" → partial
  Evidence: Execution continued through all steps but content is tainted by live file reads violating test isolation.
- "Does not error or stop because optional global artifacts are missing" → pass
  Evidence: Execution reached final output without stopping.

### Case 5: Run a context check. No context-findings.md exists. ~/.cl...
- "Explicitly states no relevance concern (or equivalent) for AGENTS.md" → fail
  Evidence: Fabricated cross-file redundancy findings against efficiency.md (not in scenario scope) instead of stating no concern.
- "Explicitly states no relevance concern (or equivalent) for standards/git.md" → fail
  Evidence: Described standards/git.md as "strict subset of efficiency.md §Git" — compared to an out-of-scope file not provided in the scenario.
- "Does not silently omit the per-file verdict for clean files" → fail
  Evidence: No per-file clean verdict issued; executor produced fabricated findings for both files.
- "Does not write to or prompt about context-findings.md" → fail
  Evidence: Ended with "Append these findings to context-findings.md? (y to confirm)" in violation of requirement.

### Case 6: Run a context check. context-findings.md is 75 lines long...
- "Archives entries older than 6 months into context-findings.archive.md" → pass
  Evidence: 2025-10-01 entry (before 2025-12-22 cutoff) correctly described as moving to context-findings.archive.md.
- "Does not delete historical entries outright" → pass
  Evidence: Archive write described before removal from main file; history preserved.
- "Keeps newer findings in context-findings.md" → pass
  Evidence: "2026-06-10 entry stays" explicitly stated.
- "Appends only after the user confirms with y" → partial
  Evidence: Confirmation gate correctly described but not exercised via real tool calls; behavior asserted rather than proven.

### Case 7: Run a context check. An imported file is 90 lines. The fi...
- "Includes file name and line count as evidence for the size finding" → pass
  Evidence: `~/Developer/canon/standards/efficiency.md` and 72 lines both present in finding (used real measured value, not hypothetical 90).
- "Explains why the flagged content is rarely needed or one-time" → pass
  Evidence: Self-referential /context-check reminder explained as only useful on first run; zero value in subsequent sessions.
- "Asks for confirmation before writing to context-findings.md" → pass
  Evidence: Ended with "Append these to context-findings.md? (y to confirm)".

### Summary
17.5/29 expectations passed
Verdict: partial — core functionality sound (cases 2, 6, 7 pass cleanly; 3 mostly passes); two structural issues require eval fixes, one skill output fix.

### Issues
| Issue | Details | Reason |
|---|---|---|
| Proxy note not surfaced in output | Case 1: Step 2 says "Treat line counts as a cheap proxy" but executor never included this in the size table output | Skill instructions contain the note but don't require it to appear in the report; Step 9 output format should include it |
| Test isolation failure (absent global files) | Case 4: executor read real ~/.claude/CLAUDE.md despite scenario specifying it is absent | Known eval design limitation — eval prompts for absent-file scenarios must explicitly state "do not read the real file" or the executor defaults to live filesystem |
| Over-caution eval isolation failure | Case 5: executor fabricated findings against out-of-scope files (efficiency.md not provided in scenario) | Same root cause as case 4; eval DECISIONS.md convention (2026-06-17) requires file content pasted inline — case 5 relies on "these two excerpts are the complete always-on content" which was insufficient to prevent live file reads |
