
## Current Focus

All externalize-dependencies tickets closed. Repo now works from any clone path, RTK and tk are both optional.

## In Progress

Nothing in progress.

## Recent Decisions

- **All AS- tickets closed** — AS-ynok (RTK optional), AS-wom4 (wrapup decoupled from tk), AS-fpax (polish → wrapup rename), AS-8ms5 (epic) all done
- **TryOuts skills cleaned up** — removed wrapup/handoff/ticket/security-review/pdf; kept general, git, code-reviewer, code-simplifier, handoff (handoff re-added for Claude↔Codex sync)
- **OpenMontage** — added handoff for Claude↔Codex sync; wrapup already present and self-contained
- **Guide step numbering fixed** — "Step 4" after "Steps 3–5" corrected to "Step 6"; PDF regenerated
- **.gitignore updated** — .tickets/ and pbcopy now excluded

## Dead Ends

- Config.md for storing install path — not needed; scripts self-locate via BASH_SOURCE at runtime

<!-- HANDOFF-SNAPSHOT:START 2026-05-01 09:54 branch:main -->
**Modified files:**
```
 M AGENTS.md
 M Emacs/init.el
 M adapters/claude/CLAUDE.md
 M guides/AI-Agents-Setup.md
 M guides/context-optimization.md
 M skills.sh
 M skills/code-reviewer.md
 M skills/code-simplifier.md
 M skills/security-review.md
 M skills/wrapup.md
 D standards/general.md
 D standards/git.md
 M tools/handoff.md
 M tools/ticket.md
?? .DS_Store
?? standards/efficiency.md
```

**Recent commits:**
```
aeae908 chore: auto-update handoff snapshot [2026-05-01 09:53]
5b24529 chore: auto-update handoff snapshot [2026-05-01 09:50]
8b61ae9 chore: auto-update handoff snapshot [2026-05-01 09:43]
27b8349 chore: auto-update handoff snapshot [2026-05-01 09:41]
b799871 chore: auto-update handoff snapshot [2026-05-01 09:36]
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-01 09:53 branch:main -->
**Modified files:**
```
 M AGENTS.md
 M Emacs/init.el
 M adapters/claude/CLAUDE.md
 M guides/AI-Agents-Setup.md
 M guides/context-optimization.md
 M skills.sh
 M skills/code-reviewer.md
 M skills/code-simplifier.md
 M skills/security-review.md
 M skills/wrapup.md
 D standards/general.md
 D standards/git.md
 M tools/handoff.md
 M tools/ticket.md
?? .DS_Store
?? standards/efficiency.md
```

**Recent commits:**
```
5b24529 chore: auto-update handoff snapshot [2026-05-01 09:50]
8b61ae9 chore: auto-update handoff snapshot [2026-05-01 09:43]
27b8349 chore: auto-update handoff snapshot [2026-05-01 09:41]
b799871 chore: auto-update handoff snapshot [2026-05-01 09:36]
e745ddb chore: auto-update handoff snapshot [2026-05-01 09:34]
```
<!-- HANDOFF-SNAPSHOT:END -->
