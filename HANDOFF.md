
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

<!-- HANDOFF-SNAPSHOT:START 2026-05-26 07:37 branch:main -->
**Modified files:**
```
 M README.md
?? standards/skill-setup-std.md
```

**Recent commits:**
```
d01c9b8 docs: tighten working memory claim — sessions need more, not burn all
b8e838b chore: auto-update handoff snapshot [2026-05-26 07:25]
0e1e8b0 docs: open with working memory hook before etymology line
aae28c0 docs: remove duplicate CLI table, screenshot is sufficient
8fdda3e docs: add doc-audit to sprint complete diagram and legend
```

**In-progress tickets:**
```
No tickets with status 'in_progress'.
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-26 07:25 branch:main -->
**Modified files:**
```
 M README.md
```

**Recent commits:**
```
0e1e8b0 docs: open with working memory hook before etymology line
aae28c0 docs: remove duplicate CLI table, screenshot is sufficient
8fdda3e docs: add doc-audit to sprint complete diagram and legend
88892b1 feat: wire doc-audit into wrapup pipeline, add command accuracy check
24604fd docs: fix Quick Start — wrapup and handoff are sub-skills, not separate installs
```

**In-progress tickets:**
```
No tickets with status 'in_progress'.
```
<!-- HANDOFF-SNAPSHOT:END -->
