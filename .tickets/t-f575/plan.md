# Plan

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-f575`
<!-- Keep this doc under ~500 words — it is injected at every session start. -->

## Sign-off
<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->
<!-- Optional, append: | Gate model: <value> -- forces the sprint-close reviewer/evaluator onto that model, overriding the automatic low-risk downgrade. Valid values (case-insensitive): a model id (e.g. haiku, sonnet, opus), or the literal "session" to force full session-model review. Omit entirely for automatic behavior -- there is no separate "auto" value; absence already means automatic. -->

Tier: normal | Risk: CSS/visual-only change to one shared file; no DOM/selector changes, confirmed no existing test asserts on computed style — regression risk is purely visual, checked by screenshot comparison in both themes.

- [x] Plan approved — proceed to implementation

## Approach

1. **Atmosphere** — replace the flat `background: var(--bg)` on `html, body` with a subtle radial gradient anchored top-left, using a new theme-aware `--glow-tint` custom property.
2. **Signature glow** — soft `box-shadow` glow on the brand-icon SVG (cyan, matches its own accent) and an inset accent glow on the active-sprint sidebar block (`#s-wip.has-items`).
3. **Typography hierarchy** — heavier weight/wider tracking on `.column-title` and `.card-title`; within the existing system-font stack, no new `font-family`.
4. **Archive/CI-badge overlap fix (supersedes `t-0ec3`'s fix)** — user found `t-0ec3`'s hide-on-hover approach was itself a band-aid ("still messed up"). Real root cause: `.card-head` is already at ~100% width with 5 normal-flow items (id, copy, type badge, CI badge, headless-run button) — there's no slack for a 6th absolutely-positioned element (`.card-archive`) to coexist without collision, regardless of element size. Fixed properly: shrank the Run button to an icon-only control (`▶`, already had a `title` tooltip, kept it) to reduce header density, and moved `.card-archive` out of `.card-head` into `.card-body` as a `float: right` element before the title — CSS text now wraps around it naturally instead of needing a guessed fixed padding reservation. Removed the `:has()` hide-on-hover rule entirely, since nothing needs hiding anymore.
5. **Modal doc-content polish** — user flagged the ticket-detail modal's rendered docs (Acceptance/Plan/etc.) as bland too. `.doc-heading-2` (section headers like "Criteria"/"Test Plan") gets the same uppercase/weight/tracking treatment as column titles, with a bottom border for separation; `.section-jump-link` (the small in-doc nav) becomes a pill-chip matching the doc-tab style instead of a plain underlined link.
6. Verify in both themes via headless-Chrome screenshots, before/after, plus live bounding-box/Playwright checks for the archive fix specifically (this was the part that broke last time despite "verification").
7. Run full `npm run test:ui` (37 tests) to confirm no regression, plus a diff grep for any external `@import`/`url(http`/`@font-face`.

## Files
- `tools/sprint-check-app/app.html` — CSS changes (background, glow, typography, doc-heading/nav styling) plus one small DOM change (moved `.card-archive` from `.card-head` to `.card-body`, no id/class renamed) and one button-label change (`.ci-run-btn` text `▶ Run` → `▶`, `title`/new `aria-label` preserve the full description).

## Decisions
- No new font import — offline-first constraint (this tool has zero network dependencies anywhere).
- Card elevation/shadow-on-hover and staggered load animation dropped from original scope — already implemented (`app.html:449-469`, `:611-619`).
- The archive-overlap fix moved an element's DOM position and shortened a button's text — this is real, not purely additive as originally planned. Verified safe: `.card-archive`/`.ci-run-btn` class names are unchanged (only their container/content changed), and the existing Playwright suite selects by class/id, never DOM position — confirmed via a full 37-test run plus dedicated bounding-box verification of the specific fix (learned from `t-0ec3`: a claimed "verified" fix that wasn't actually tested against the real shipped sequence, don't repeat that mistake).
- Chose `float: right` over a fixed `padding-right` reservation on the title — text-wrap-around-float is exact for any title length, a padding guess would need re-tuning per content and could still break on edge cases.
