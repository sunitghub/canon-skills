
## Current Focus

README shipped. Canon is ready to publish to npm.

## In Progress

Nothing in progress.

## Recent Decisions

- **sprint-check symlink fix** — `${BASH_SOURCE[0]}` returned the symlink path (`~/bin/sprint-check`) instead of the real file, so `SCRIPT_DIR` was wrong. Fixed with standard `readlink` loop in `tools/sprint-check.sh`.
- **README fully rewritten** — hero pitch, sprint-check section with 5 screenshots, contrast table (canon vs agent frameworks), npx install path, live-reference model explanation. Tagline: "Your agents are capable. Canon makes them yours."
- **Screenshots in `meta/screenshots/`** — board-light.png, board-dark.png, commit-detail.png, new-ticket.png, ticket-completeness.png. All committed to repo.
- **npm package ready** — `bin/install.js`, `package.json` (name: `canon-skills`), `.npmignore`, and `meta/publishing.md` runbook all in place from prior session.

## Next Steps

1. **Publish to npm** — user needs an npm account (npmjs.com). Then:
   ```bash
   npm pack --dry-run /Users/Sunit/Developer/canon   # verify only 3 files
   npm publish /Users/Sunit/Developer/canon --access public
   npm info canon-skills   # verify live
   npx canon-skills@latest  # smoke test
   ```
2. **Verify sprint-check symlink fix** works in asterisk project (run `sprint-check` from that project dir).
3. **After npm publish**: update README install section if any friction found during smoke test.

## Dead Ends

- Textual TUI for sprint-check — breaks zero-install guarantee; rejected.
- Config.md for storing install path — not needed; scripts self-locate via BASH_SOURCE at runtime.

<!-- HANDOFF-SNAPSHOT:START 2026-05-21 20:12 branch:main -->
**Modified files:**
```
 M README.md
 M guides/AI-Agents-Setup.md
 M skills/sprint.md
?? skills/orient.md
```

**Recent commits:**
```
7cdd5fb chore: auto-update handoff snapshot [2026-05-21 20:11]
3f0c756 chore: auto-update handoff snapshot [2026-05-21 20:03]
4266c32 chore: update handoff — README shipped, npm publish is next step
e56cab0 docs: add ticket completeness screenshot to README sprint-check section
aa1d1f3 docs: rewrite README with sprint-check screenshots and live-reference pitch
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-05-21 20:11 branch:main -->
**Modified files:**
```
 M README.md
 M guides/AI-Agents-Setup.md
 M skills/sprint.md
?? skills/orient.md
```

**Recent commits:**
```
3f0c756 chore: auto-update handoff snapshot [2026-05-21 20:03]
4266c32 chore: update handoff — README shipped, npm publish is next step
e56cab0 docs: add ticket completeness screenshot to README sprint-check section
aa1d1f3 docs: rewrite README with sprint-check screenshots and live-reference pitch
e6bac4f fix: resolve symlinks in sprint-check.sh so ~/bin symlink works
```
<!-- HANDOFF-SNAPSHOT:END -->
