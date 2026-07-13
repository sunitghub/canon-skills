# Acceptance

<!-- Keep the Ticket line below unchanged. -->
Ticket: `t-f575`

## Criteria
The checklist of behavior that must be true before the sprint can close.
<!-- Add or edit checklist items below. Keep this heading unchanged. -->

- [x] Page background reads as an atmospheric surface (subtle gradient/vignette), not a flat solid fill, in both dark and light theme. `radial-gradient(1100px 700px at 14% -8%, var(--glow-tint), transparent 62%), var(--bg)` on `html, body`, with theme-specific `--glow-tint`.
- [x] The logo mark / active-sprint header area has a deliberate signature moment (soft glow/accent), not just a small static icon — present in both themes. `.brand-icon` gets a cyan `box-shadow` glow (matches the icon's own cyan accent); `#s-wip.has-items` (active-sprint sidebar block) gets an inset accent-colored glow.
- [x] Column headers and card titles have clear typographic hierarchy (weight/size/tracking contrast vs. body/metadata text) — no new font import, built from the existing system-font stack. `.column-title` weight 600→750, tracking .04em→.07em; `.card-title` weight 500→600.
- [x] No `id`/`class` renamed or removed anywhere the existing Playwright suite selects against — CSS/visual-only except one deliberate, verified fix (below). Confirmed: full 37-test suite passes unmodified.
- [x] Both `html[data-theme="light"]` and the dark default are fully supported for every new/changed style — no dark-only treatment. `--glow-tint` defined per-theme; glow/typography changes use existing theme-aware variables, verified via before/after screenshots in both themes.
- [x] **Archive/CI-badge overlap on closed+`ci:true` cards is genuinely fixed** (supersedes `t-0ec3`, which the user found still broken — its hide-on-hover approach was a band-aid, not a real fix). `.card-archive` moved from `.card-head` (absolutely positioned, competing with badges for the same fixed-width zone with zero slack) to `.card-body` as a `float: right` element before the title. `.ci-run-btn` shrunk to icon-only (`▶`, tooltip preserved via existing `title` + new `aria-label`). Verified via direct bounding-box measurement on the real `t-200b` card, not just a screenshot glance — no overlap in either direction (badges vs. run icon vs. archive vs. title text, including a long wrapping title).
- [x] Modal doc-content ("Criteria"/"Test Plan" section headers, in-doc nav pills) gets the same typographic treatment as the board — `.doc-heading-2` uppercase/weight/tracking + bottom border; `.section-jump-link` becomes a pill-chip matching `.doc-tab`'s style.

## Test Plan
The commands or checks that prove the criteria work.
<!-- Add or edit test commands below. Keep this heading unchanged. -->

- [x] Full `npm run test:ui` suite (37 tests) passes with no regressions (one pre-existing intermittent flake, `markdown syntax shown as an inline-code example...`, reproduced passing cleanly in isolation — same known flake from `t-978c`/`t-f575`'s earlier passes, not caused by this diff).
- [x] Visual check via headless-Chrome screenshots in both dark and light theme, before/after comparison — reviewed directly.
- [x] Confirm no new network/font/CDN dependency was introduced (grep the diff for `@import`, `url(http`, `@font-face` pointing anywhere external) — clean, no matches.
- [x] **Direct bounding-box verification of the archive/badge fix** on the real `t-200b` card and a synthetic open+`ci:true` card with a long wrapping title — confirmed no overlap in any direction, not inferred from a screenshot alone (this is exactly the class of claim that `t-0ec3`'s first "verification" got wrong).

## QA
<!-- Add sign-off items below. Keep this heading unchanged. -->
Edge cases and sign-off.
<!-- Add or edit QA items below. Keep this heading unchanged. -->

- [x] Tested locally — full Playwright suite, before/after screenshots in both themes, bounding-box verification of the archive fix specifically, external-dependency grep all confirm the change is clean.

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| code-simplifier | ran | reviewed the full accumulated diff in-context — no simplification opportunity, the float+clearfix approach is the minimal correct fix |
| code-reviewer | ran | reviewed both commits together against the 8-dimension checklist — no findings, matches fresh reviewer's independent YES on the complete diff |
| reviewer | ran | verdict: YES (model: claude-sonnet-5) — independently reproduced the archive fix via live bounding-box/glyph measurement, not a screenshot glance |
| security-review | skipped | pure CSS/visual change, no auth/secrets/input-handling/API-endpoint surface |
| repo-check | skipped | no repo workflow/docs/skills/tools surface changed, single app.html edit |
| doc-audit | skipped | no README/guides/docs content changed |
| eval | ran | verdict: pass — eval-report.md written (model: claude-sonnet-5), independently reproduced the fix against both the real t-200b card and an adversarial synthetic long-title card, not trusting the ticket's own narrative |
