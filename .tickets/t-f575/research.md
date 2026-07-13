# Research

Ticket: `t-f575`

## Objective
What's actually missing from the board's current visual design vs. what the ticket assumed, before committing to a scope.

## Relevant Files
| File | Why relevant | Evidence |
|---|---|---|
| `tools/sprint-check-app/app.html:11-30` | Current dark palette — already structurally close to the "Harmony" reference (near-black bg, purple accent, colored status borders) | `--bg: #0d0d10; --accent: #7c6af7;` |
| `tools/sprint-check-app/app.html:449-469` | Card already has hover elevation: lift (`translateY(-1px)`), layered box-shadow using a per-column `--card-glow` custom property, and a gradient top-bar that reveals on hover | `.card:hover { transform: translateY(-1px); box-shadow: ... }` `.card::before { ... transform: scaleX(0) ... }` |
| `tools/sprint-check-app/app.html:611-619` | Staggered card entrance animation already exists — bouncy easing, delay indexed by card position | `animation-delay: calc(var(--i, 0) * 35ms);` |
| `tools/sprint-check-app/app.html:65-66` | `html, body { background: var(--bg); }` — flat solid fill, no gradient/atmosphere | — |
| `tools/sprint-check-app/app.html:66` | Body font is the system stack (`-apple-system, ... system-ui`); JetBrains Mono is already used distinctively for IDs/branch names/tokens | `font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;` |
| `tests/sprint-check-app.spec.js` | 37 tests, all select by `id`/`class`/text content, none assert on computed visual style (color, shadow, gradient) | confirmed via grep — no `getComputedStyle`/color assertions found |

## System Model
- Two of the five originally-proposed changes are **already implemented** and don't need work: card elevation/shadow-on-hover, and the staggered load animation. Scoping these back out narrows the ticket to genuine gaps.
- The real gaps are: (1) flat solid background with no atmosphere/depth, (2) no signature glow/branding moment beyond a small static logo mark, (3) typography relies entirely on default weight/size for hierarchy — no deliberate contrast between column headers, card titles, and metadata.
- **Constraint that shapes the typography approach**: this is a local, offline-first dev tool (stdlib-only Python server, no build step, no CDN dependency anywhere in the app). Importing an external display font via `@font-face`/web font CDN would add a network dependency this tool doesn't currently have anywhere — out of character and a real functional risk (a user running this fully offline would get a layout shift or missing font). Hierarchy should be built from weight/size/tracking within the existing system-font stack, not a new font import.
- No visual/CSS-only change risks breaking the 37 existing Playwright tests — confirmed none assert on computed style, only structure/text/attribute presence.

## Constraints
- Must not change DOM structure, `id`s, or `class` names the test suite selects against (already true of nearly any CSS-only change, worth stating explicitly per the ticket's own text).
- Must stay offline-first — no new external font/asset network dependency.
- Preserve both dark and light theme support (`html[data-theme="light"]` override pattern already used pervasively) — any new atmosphere/glow effect needs a light-theme counterpart, not just a dark-mode-only treatment.

## Unknowns
- None blocking — this is a visual refinement with low structural risk (single file, no new endpoints, no test-selector changes).

## Not In Scope
- Card elevation/shadow-on-hover — already implemented (`app.html:449-469`).
- Staggered load animation — already implemented (`app.html:611-619`).
- Any new external font/icon library — offline-first constraint.
