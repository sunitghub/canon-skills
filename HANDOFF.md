
## Current Focus

Bundled tkt ticket tool shipped; canon repo fully self-contained with no external ticket dependency.

## In Progress

Nothing in progress.

## Recent Decisions

- **tkt bundled in tools/tkt.sh** — replaces `tk` (brew install) with a self-contained bash script; same `.tickets/` format so upgrade to full `tk` is seamless
- **ticket skill now visible** — removed `hidden: true`; appears in `skills list` and is auto-added when wrapup is registered
- **skills add wrapup auto-adds ticket** — and prompts to add canon/tools to PATH; skips if ticket already registered
- **skills refresh condensed** — one line per skill (`[ok]` or `[updated]`), silent on no-change
- **skills status PATH check** — ticket row shows `(tkt on PATH)` or `(tkt not on PATH)`; "Action needed" block appears at bottom if tkt is missing from PATH
- **dep tree/cycle dropped** — approve workflow simplified to: wrapup → tkt close
- **Setup guide updated** — removed brew install instructions, rewrote ticketing section for tkt, PDF regenerated

## Dead Ends

- Config.md for storing install path — not needed; scripts self-locate via BASH_SOURCE at runtime
- DateTime-based staleness check for skills refresh — not needed; @-imports are live references, content changes take effect automatically

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 11:15 branch:main -->
**Modified files:**
```
 M .tickets/AS-ynok.md
 M tools/sprint-check/app.html
```

**Recent commits:**
```
39c7a8f chore: auto-update handoff snapshot [2026-05-20 11:14]
2f1bd4b chore: auto-update handoff snapshot [2026-05-20 11:12]
a5246fc chore: auto-update handoff snapshot [2026-05-20 11:08]
a154394 feat: companion docs tabs + inline edit in ticket modal
0431250 chore: auto-update handoff snapshot [2026-05-20 10:56]
```

**In-progress tickets:**
```
t-ialk   [in_progress] - Build sprint-check GUI — kanban app.html + Python server
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 11:14 branch:main -->
**Modified files:**
```
 M .tickets/AS-ynok.md
 M tools/sprint-check/app.html
```

**Recent commits:**
```
2f1bd4b chore: auto-update handoff snapshot [2026-05-20 11:12]
a5246fc chore: auto-update handoff snapshot [2026-05-20 11:08]
a154394 feat: companion docs tabs + inline edit in ticket modal
0431250 chore: auto-update handoff snapshot [2026-05-20 10:56]
53d0c26 feat: drag-drop between columns, sort newest-first, readability fixes
```

**In-progress tickets:**
```
t-ialk   [in_progress] - Build sprint-check GUI — kanban app.html + Python server
```
<!-- HANDOFF-SNAPSHOT:END -->
