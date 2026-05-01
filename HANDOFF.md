
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-01 10:08 branch:main -->
**Modified files:**
```
?? .DS_Store
```

**Recent commits:**
```
57ae2de feat(emacs): add markdown-mode and visual-line-mode hooks, remove commented keybindings
7fad0f7 chore: auto-update handoff snapshot [2026-05-01 10:08]
e3303ea feat(skills): consolidate standards, simplify catalog, add refresh command
3fc5c42 chore: auto-update handoff snapshot [2026-05-01 10:06]
3b90cf3 chore: auto-update handoff snapshot [2026-05-01 10:02]
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-01 10:08 branch:main -->
**Modified files:**
```
 M Emacs/init.el
?? .DS_Store
```

**Recent commits:**
```
e3303ea feat(skills): consolidate standards, simplify catalog, add refresh command
3fc5c42 chore: auto-update handoff snapshot [2026-05-01 10:06]
3b90cf3 chore: auto-update handoff snapshot [2026-05-01 10:02]
ee1848f chore: auto-update handoff snapshot [2026-05-01 09:54]
aeae908 chore: auto-update handoff snapshot [2026-05-01 09:53]
```
<!-- HANDOFF-SNAPSHOT:END -->
