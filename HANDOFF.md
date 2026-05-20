
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-20 09:40 branch:main -->
**Modified files:**
```
?? tools/sprint-check.sh
?? tools/sprint-check/
```

**Recent commits:**
```
f9078a1 feat: add changes summary table to wrapup final output
8344b7b feat: silent-pass for all-LOW impact — only surface when risk is present
fbddcff chore: expand sprint skills list summary to describe impact analysis flow
a1f41d7 feat: add impact-analysis sub-skill and wire into sprint
1a33da2 docs: update setup guide with Action Endpoint Patterns, inject sprint note
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-17 20:21 branch:main -->
**Modified files:**
```
 M skills.sh
```

**Recent commits:**
```
8eb1181 docs: clarify ast-grep built-in patterns need no project setup
4fda1a1 docs: mention efficiency standard is auto-injected on skill registration
7f053bb feat: wire ast-grep as optional pre-scan step in security-review
707cc50 docs: regenerate setup guide PDF
13c2365 docs: fix init command in deck to use cd && ./skills.sh form
```
<!-- HANDOFF-SNAPSHOT:END -->
