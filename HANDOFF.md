
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 09:55 branch:main -->
**Modified files:**
```
?? tools/sprint-check.sh
?? tools/sprint-check/
```

**Recent commits:**
```
ee11355 chore: auto-update handoff snapshot [2026-05-20 09:55]
1e28bda chore: auto-update handoff snapshot [2026-05-20 09:49]
53f1300 chore: auto-update handoff snapshot [2026-05-20 09:48]
3baf883 chore: auto-update handoff snapshot [2026-05-20 09:45]
eaa1b80 chore: auto-update handoff snapshot [2026-05-20 09:40]
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 09:55 branch:main -->
**Modified files:**
```
?? tools/sprint-check.sh
?? tools/sprint-check/
```

**Recent commits:**
```
1e28bda chore: auto-update handoff snapshot [2026-05-20 09:49]
53f1300 chore: auto-update handoff snapshot [2026-05-20 09:48]
3baf883 chore: auto-update handoff snapshot [2026-05-20 09:45]
eaa1b80 chore: auto-update handoff snapshot [2026-05-20 09:40]
f9078a1 feat: add changes summary table to wrapup final output
```
<!-- HANDOFF-SNAPSHOT:END -->
