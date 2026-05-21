
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 19:11 branch:main -->
**Modified files:**
```
 M skills.sh
```

**Recent commits:**
```
c324358 fix: refresh correctly removes @-import from AGENTS.md for pruned deps
7f57653 fix: refresh also removes stale @-import from AGENTS.md when pruning covered deps
f1c0624 fix: skills list shows standards; help strips @-imports; update CATALOG.md
8007062 fix: addall skips skills already covered as transitive deps
9c32789 feat: pre-fill description with type template on new ticket modal open
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 16:15 branch:main -->
**Modified files:**
```
 M tools/sprint-check/app.html
```

**Recent commits:**
```
3015f94 chore: auto-update handoff snapshot [2026-05-20 16:14]
84b5eec chore: move sprint-check-guide.pdf to guides/
aded0d1 docs: add sprint-check-guide.pdf
f8fa89f feat: auto-add canon/tools to PATH on skills add sprint-check; update guide with screenshot
c8bc9b4 feat: sprint-check UX polish — readiness indicator, WIP click-to-open, modal cleanup
```
<!-- HANDOFF-SNAPSHOT:END -->
