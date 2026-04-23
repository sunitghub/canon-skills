
## Current Focus

Externalizing hard dependencies so the repo works from any clone path and without requiring RTK or tk.

## In Progress

| Ticket | Title | Status |
|--------|-------|--------|
| AS-8ms5 | Externalize hard dependencies from skill setup | open (epic) |
| AS-ynok | Make RTK optional in agent init | open |
| AS-wom4 | Decouple wrapup skill from ticket system | open |
| AS-fpax | Rename polish skill to wrapup | open (blocked by AS-wom4) |

Dependency order: AS-ynok and AS-wom4 are independent, AS-fpax depends on AS-wom4.

## Recent Decisions

- **skills.sh init added** — lightweight Claude-only hook setup, no path restriction, idempotent (handles ~ vs absolute path comparison)
- **~/Developer hardcoding removed** — `init-agent.sh` no longer warns or blocks if repo isn't at standard path; all scripts self-locate via BASH_SOURCE
- **AGENTS.md updated** — skill discovery section now uses `<path-to-AI-Skills>` placeholder so AI agents don't suggest wrong paths
- **Guide updated** — `guides/AI-Agents-Setup.md` uses `$SKILLS` shell variable throughout; PDF regenerated
- **RTK decision** — RTK is token optimization only, not required for skills. Will make it optional in init-agent.sh with OS-aware hints
- **Wrapup scope** — "unit of work" stays session-scoped (current behavior). No structural change to skill needed; ticket integration via auto-trigger hook remains optional for ticket users
- **Rename rationale** — "wrapup" better conveys closure of a work unit vs "polish" which implies cosmetic

## What's Next

1. AS-ynok: Make RTK optional — `init-agent.sh setup_claude` should warn+skip RTK hook if absent, not abort
2. AS-wom4: Update guide + skill body to make clear ticket is not required for wrapup
3. AS-fpax: Rename polish.md → wrapup.md, update all references, add migration note

## Dead Ends

- Config.md for storing install path — not needed; scripts self-locate via BASH_SOURCE at runtime

<!-- HANDOFF-SNAPSHOT:START 2026-04-23 08:56 branch:main -->
**Modified files:**
```
?? skills/shorts-director.md
```

**Recent commits:**
```
715226f chore: auto-update handoff snapshot [2026-04-23 08:53]
d11c7e9 chore: auto-update handoff snapshot [2026-04-23 08:51]
c00c24b Fix stale path duplication in cmd_add
cefc304 chore: auto-update handoff snapshot [2026-04-22 15:18]
32c564a addall: back up config files, fix duplicate dependency output
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-04-23 08:53 branch:main -->
**Modified files:**
```
?? skills/shorts-director.md
```

**Recent commits:**
```
d11c7e9 chore: auto-update handoff snapshot [2026-04-23 08:51]
c00c24b Fix stale path duplication in cmd_add
cefc304 chore: auto-update handoff snapshot [2026-04-22 15:18]
32c564a addall: back up config files, fix duplicate dependency output
9f6154e Fix addall showing duplicate skills from wrapup dependencies
```
<!-- HANDOFF-SNAPSHOT:END -->
