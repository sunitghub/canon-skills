
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

<!-- HANDOFF-SNAPSHOT:START 2026-04-22 09:51 branch:main -->
**Modified files:**
```
 M AGENTS.md
 D README.pdf
 M guides/AI-Agents-Setup.md
 M guides/AI-Agents-Setup.pdf
 M init-agent.sh
 M scripts/auto-polish-trigger.sh
 D scripts/init-polish.sh
 M scripts/pre-commit-check.sh
 M skills.sh
 M skills/code-reviewer.md
 M skills/code-simplifier.md
 D skills/polish.md
 M skills/security-review.md
 M tools/handoff.md
 M tools/ticket.md
?? .tickets/
?? scripts/init-wrapup.sh
?? skills/wrapup.md
?? temp.txt
```

**Recent commits:**
```
a8345fc chore: auto-update handoff snapshot [2026-04-22 09:46]
19cb9fd chore: auto-update handoff snapshot [2026-04-22 09:22]
3328481 chore: auto-update handoff snapshot [2026-04-22 09:10]
80c52e2 chore: auto-update handoff snapshot [2026-04-22 08:16]
6fc3e0b Simplify approve: root ID only, agent walks dep tree automatically
```
<!-- HANDOFF-SNAPSHOT:END -->

<!-- HANDOFF-SNAPSHOT:START 2026-04-22 09:46 branch:main -->
**Modified files:**
```
 M AGENTS.md
 M HANDOFF.md
 D README.pdf
 M guides/AI-Agents-Setup.md
 M guides/AI-Agents-Setup.pdf
 M init-agent.sh
 M scripts/auto-polish-trigger.sh
 D scripts/init-polish.sh
 M scripts/pre-commit-check.sh
 M skills.sh
 M skills/code-reviewer.md
 M skills/code-simplifier.md
 D skills/polish.md
 M skills/security-review.md
 M tools/handoff.md
 M tools/ticket.md
?? .tickets/
?? scripts/init-wrapup.sh
?? skills/wrapup.md
?? temp.txt
```

**Recent commits:**
```
19cb9fd chore: auto-update handoff snapshot [2026-04-22 09:22]
3328481 chore: auto-update handoff snapshot [2026-04-22 09:10]
80c52e2 chore: auto-update handoff snapshot [2026-04-22 08:16]
6fc3e0b Simplify approve: root ID only, agent walks dep tree automatically
12c883f Add dependency case to ticket workflow steps
```
<!-- HANDOFF-SNAPSHOT:END -->
