
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
   npm pack --dry-run ~/Developer/canon   # verify only 3 files
   npm publish ~/Developer/canon --access public
   npm info canon-skills   # verify live
   npx canon-skills@latest  # smoke test
   ```
2. **After npm publish**: update README install section if any friction found during smoke test.

## Dead Ends

- Textual TUI for sprint-check — breaks zero-install guarantee; rejected.
- adapters/ as a global CLAUDE.md shim — never auto-wired, so removed in favour of direct imports.

<!-- HANDOFF-SNAPSHOT:START 2026-05-25 17:16 branch:main -->
**Modified files:**
```
 M meta/screenshots/board-dark.png
 M meta/screenshots/board-light.png
 M meta/screenshots/commit-detail.png
```

**Recent commits:**
```
4a604c5 chore: auto-update handoff snapshot [2026-05-25 17:15]
323d980 chore: auto-update handoff snapshot [2026-05-25 17:14]
d87e937 chore: auto-update handoff snapshot [2026-05-25 17:13]
08269ae docs: shorten sprint start node labels to fit diagram width
a6c3390 docs: improve sprint diagram section formatting
```

**In-progress tickets:**
```
No tickets with status 'in_progress'.
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-25 17:15 branch:main -->
**Modified files:**
```
 M meta/screenshots/board-dark.png
 M meta/screenshots/board-light.png
```

**Recent commits:**
```
323d980 chore: auto-update handoff snapshot [2026-05-25 17:14]
d87e937 chore: auto-update handoff snapshot [2026-05-25 17:13]
08269ae docs: shorten sprint start node labels to fit diagram width
a6c3390 docs: improve sprint diagram section formatting
2a48995 style: split NOTICED rule into its own bullet in efficiency.md
```

**In-progress tickets:**
```
No tickets with status 'in_progress'.
```
<!-- HANDOFF-SNAPSHOT:END -->
