
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 14:22 branch:main -->
**Modified files:**
```
 M tools/sprint-check/app.html
```

**Recent commits:**
```
f9179a1 chore: auto-update handoff snapshot [2026-05-20 14:21]
9e198a0 chore: auto-update handoff snapshot [2026-05-20 14:20]
1188942 chore: auto-update handoff snapshot [2026-05-20 14:19]
b4e28a0 chore: auto-update handoff snapshot [2026-05-20 14:18]
fbeb6eb chore: auto-update handoff snapshot [2026-05-20 14:17]
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 14:21 branch:main -->
**Modified files:**
```
 M tools/sprint-check/app.html
```

**Recent commits:**
```
9e198a0 chore: auto-update handoff snapshot [2026-05-20 14:20]
1188942 chore: auto-update handoff snapshot [2026-05-20 14:19]
b4e28a0 chore: auto-update handoff snapshot [2026-05-20 14:18]
fbeb6eb chore: auto-update handoff snapshot [2026-05-20 14:17]
65e71dd chore: auto-update handoff snapshot [2026-05-20 14:15]
```
<!-- HANDOFF-SNAPSHOT:END -->
