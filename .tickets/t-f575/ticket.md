---
id: t-f575
status: closed
created: 2026-07-13T13:37:11Z
type: task
priority: 3
eval_override: false
ci: true
---
# Refresh sprint-check board visual design (depth, motion, hierarchy)

Board currently feels bland/flat per user feedback. Direction agreed: (1) subtle radial gradient/vignette background instead of flat --bg fill, for atmosphere/depth; (2) real card elevation (shadow + lift on hover) instead of just border recolor; (3) a signature glow accent behind the logo mark / active-sprint indicator; (4) sharper typography hierarchy for column headers and card titles (more weight/tracking contrast), keeping JetBrains Mono for IDs/tokens as-is (already distinctive); (5) one deliberate motion moment -- staggered card reveal on load using the existing .animate-in/--i index hooks, rather than scattered micro-animations. CSS/visual-only scope -- must not change any DOM structure, ids, or classes the 37 existing Playwright tests (tests/sprint-check-app.spec.js) select against. Inspiration referenced by user: a dark 'Harmony' kanban board (closest match to current structure) and two lighter AI-agent dashboards (Bork Agent, an HR dashboard) for motion/depth cues, not literal palette or layout to copy.
