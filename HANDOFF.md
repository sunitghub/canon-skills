
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-17 18:42 branch:main -->
**Modified files:**
```
 M guides/AI-Agents-Deck.md
 M guides/AI-Agents-Setup.md
```

**Recent commits:**
```
98ae04b feat: consolidate setup into skills init + add hook health to status
84e3f90 fix: use data-background-image for arcs; inline style for tagline
19ca516 fix: tagline visibility + remove full-width h1 border
81c1ae1 fix: move tagline below h1, drop problems slide, logo to CSS corner
484d2d1 feat: add canon tagline to title slide
```
<!-- HANDOFF-SNAPSHOT:END -->
