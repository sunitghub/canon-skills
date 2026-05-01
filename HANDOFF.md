
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-01 09:20 branch:main -->
**Modified files:**
```
 M Emacs/init.el
?? .DS_Store
```

**Recent commits:**
```
00d9163 chore: auto-update handoff snapshot [2026-05-01 09:18]
15b701d chore: auto-update handoff snapshot [2026-05-01 09:17]
21e5039 Add keybindings and mouse support to Emacs config
7f06fcd Add author comment to init.el
c691463 Add Emacs init.el to canon repo
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-01 09:18 branch:main -->
**Modified files:**
```
 M Emacs/init.el
?? .DS_Store
```

**Recent commits:**
```
15b701d chore: auto-update handoff snapshot [2026-05-01 09:17]
21e5039 Add keybindings and mouse support to Emacs config
7f06fcd Add author comment to init.el
c691463 Add Emacs init.el to canon repo
a45a968 refactor(statusline): consolidate install into statusline.sh, remove init-statusline.sh
```
<!-- HANDOFF-SNAPSHOT:END -->
