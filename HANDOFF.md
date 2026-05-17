
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-17 18:55 branch:main -->
**Modified files:**
```
 M guides/AI-Agents-Deck.md
```

**Recent commits:**
```
5090b24 docs: clarify sprint brief source — proposal vs codebase analysis
bb3813c chore: auto-update handoff snapshot [2026-05-17 18:52]
4cedb05 docs: split session example into existing vs new project walkthroughs
4056473 chore: auto-update handoff snapshot [2026-05-17 18:51]
831b766 docs: clarify new vs existing project setup and DECISIONS.md creation
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-17 18:52 branch:main -->
**Modified files:**
```
 M guides/AI-Agents-Deck.md
```

**Recent commits:**
```
4cedb05 docs: split session example into existing vs new project walkthroughs
4056473 chore: auto-update handoff snapshot [2026-05-17 18:51]
831b766 docs: clarify new vs existing project setup and DECISIONS.md creation
a76478c chore: auto-update handoff snapshot [2026-05-17 18:48]
8bc2fa7 docs: restructure setup guide — example session before layer detail
```
<!-- HANDOFF-SNAPSHOT:END -->
