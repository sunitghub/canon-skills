
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 14:15 branch:main -->
**Modified files:**
```
 M tools/sprint-check/app.html
```

**Recent commits:**
```
6b6aff3 chore: auto-update handoff snapshot [2026-05-20 14:15]
2f1a991 chore: auto-update handoff snapshot [2026-05-20 14:13]
caf12cf chore: auto-update handoff snapshot [2026-05-20 14:13]
8da3a9d chore: auto-update handoff snapshot [2026-05-20 14:12]
7ae568b chore: auto-update handoff snapshot [2026-05-20 14:09]
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 14:15 branch:main -->
**Modified files:**
```
 M tools/sprint-check/app.html
```

**Recent commits:**
```
2f1a991 chore: auto-update handoff snapshot [2026-05-20 14:13]
caf12cf chore: auto-update handoff snapshot [2026-05-20 14:13]
8da3a9d chore: auto-update handoff snapshot [2026-05-20 14:12]
7ae568b chore: auto-update handoff snapshot [2026-05-20 14:09]
60bd7ba chore: auto-update handoff snapshot [2026-05-20 14:09]
```
<!-- HANDOFF-SNAPSHOT:END -->
