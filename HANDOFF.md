
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-17 19:06 branch:main -->
**Modified files:**
```
 M guides/AI-Agents-Deck.md
```

**Recent commits:**
```
2d18e0d chore: auto-update handoff snapshot [2026-05-17 19:06]
a7bcfb1 chore: auto-update handoff snapshot [2026-05-17 19:04]
9b688b6 feat: auto-create HANDOFF.md on first sprint start if absent
2a8f7aa chore: auto-update handoff snapshot [2026-05-17 19:02]
faaacc6 docs: add summary table of what gets created and by whom after setup
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-17 19:06 branch:main -->
**Modified files:**
```
 M guides/AI-Agents-Deck.md
```

**Recent commits:**
```
a7bcfb1 chore: auto-update handoff snapshot [2026-05-17 19:04]
9b688b6 feat: auto-create HANDOFF.md on first sprint start if absent
2a8f7aa chore: auto-update handoff snapshot [2026-05-17 19:02]
faaacc6 docs: add summary table of what gets created and by whom after setup
81a8922 chore: auto-update handoff snapshot [2026-05-17 19:01]
```
<!-- HANDOFF-SNAPSHOT:END -->
