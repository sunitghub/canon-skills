
## Current Focus

Codebase wrapup complete across scripts/, skills/, tools/, and adapters/.
Canon is clean and ready to publish to npm.

## In Progress

Nothing in progress.

## Recent Decisions

- **Full wrapup pass (scripts/)** — fixed 4 bugs: cwd drift in all hook scripts (now use `git rev-parse --show-toplevel`), tkt binary derived from BASH_SOURCE not PATH, `statusline.sh` cache dir renamed from `waza-` to `canon-`, `check-plugins.sh` shell interpolation into Python heredoc fixed.
- **Full wrapup pass (skills/)** — removed Getting Started sections from hidden skills (−71 lines context overhead), removed ES/TS-specific conventions from code-simplifier, removed legacy polish migration note from wrapup.
- **Full wrapup pass (tools/)** — `server.py`: moved imports to top level, fixed re.sub backreference injection via lambda, moved Content-Length parse inside try block, added Origin header CSRF guard on POST endpoints.
- **adapters/ removed** — `adapters/claude/CLAUDE.md` was a shim never wired by `skills.sh init`. Deleted it; updated `~/.claude/CLAUDE.md` to import AGENTS.md and efficiency.md directly.
- **License audit** — added MIT LICENSE, removed pdf skill (Anthropic proprietary), removed company IP (octave assets, AI-Agents-Deck.md), removed personal-only shorts-director.md.
- **orient sub-skill + convention capture** — sprint start now maps the subsystem (orient); sprint complete proposes AGENTS.md updates for learnings captured during the sprint.
- **Pi handoff.ts** — replaced hardcoded `~/Developer/canon` path with `resolveAutoHandoff()` reading `~/.config/canon/install_path`.

## Next Steps

1. **Publish to npm** — user needs an npm account (npmjs.com). Then:
   ```bash
   npm pack --dry-run /Users/Sunit/Developer/canon   # verify only 3 files
   npm publish /Users/Sunit/Developer/canon --access public
   npm info canon-skills   # verify live
   npx canon-skills@latest  # smoke test
   ```
2. **After npm publish**: update README install section if any friction found during smoke test.

## Dead Ends

- Textual TUI for sprint-check — breaks zero-install guarantee; rejected.
- adapters/ as a global CLAUDE.md shim — never auto-wired, so removed in favour of direct imports.

<!-- HANDOFF-SNAPSHOT:START 2026-05-23 21:29 branch:main -->
**Modified files:**
```
 M guides/AI-Agents-Setup.md
```

**Recent commits:**
```
d6cf1cf feat: add personal/private content check to doc-audit
e15c03a feat: add doc-audit skill and doc-findings evidence log
f05a16b docs: correct team propagation claim in README
fb4374c docs: remove upfront external tool dependencies
c2381ba docs: clarify plan.md location in README sprint description
```

**In-progress tickets:**
```
No tickets with status 'in_progress'.
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-23 20:37 branch:main -->
**Modified files:**
```
 M AGENTS.md
 M CATALOG.md
 M skills/context-check.md
 M standards/context-findings.md
```

**Recent commits:**
```
0cd2d5f chore: auto-update handoff snapshot [2026-05-23 20:35]
4c5dc52 chore: auto-update handoff snapshot [2026-05-23 20:35]
e230026 chore: auto-update handoff snapshot [2026-05-23 20:31]
575d8be docs: proofread and expand README for public release
9c84514 chore: auto-update handoff snapshot [2026-05-23 19:14]
```

**In-progress tickets:**
```
No tickets with status 'in_progress'.
```
<!-- HANDOFF-SNAPSHOT:END -->
