
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 13:40 branch:main -->
**Modified files:**
```
 M .tickets/AS-ynok.md
```

**Recent commits:**
```
234cbd9 feat: clickable commits — show full message, files changed, related tickets
adbebc5 chore: auto-update handoff snapshot [2026-05-20 11:50]
a99db9b chore: auto-update handoff snapshot [2026-05-20 11:49]
ff362d5 chore: auto-update handoff snapshot [2026-05-20 11:48]
aa098e7 chore: auto-update handoff snapshot [2026-05-20 11:47]
```

**In-progress tickets:**
```
t-ialk   [in_progress] - Build sprint-check GUI — kanban app.html + Python server
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 11:50 branch:main -->
**Modified files:**
```
 M .tickets/AS-ynok.md
 M tools/sprint-check/server.py
```

**Recent commits:**
```
a99db9b chore: auto-update handoff snapshot [2026-05-20 11:49]
ff362d5 chore: auto-update handoff snapshot [2026-05-20 11:48]
aa098e7 chore: auto-update handoff snapshot [2026-05-20 11:47]
11f05c2 chore: auto-update handoff snapshot [2026-05-20 11:42]
ff1370c feat: create ticket modal with intelligent type detection
```

**In-progress tickets:**
```
t-ialk   [in_progress] - Build sprint-check GUI — kanban app.html + Python server
```
<!-- HANDOFF-SNAPSHOT:END -->
