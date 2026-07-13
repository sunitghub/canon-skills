# Review Notes

Ticket: `t-f575`
Reviewed: 2026-07-12
Model: claude-sonnet-5

## Findings

No findings.

Full accumulated diff reviewed (both commits, `8351f04` atmosphere/glow/typography + `9d9ba1d` archive-fix/modal-doc polish), scoped to `tools/sprint-check-app/app.html` only per `git diff --name-only $(git merge-base HEAD origin/main) HEAD`.

Extra scrutiny applied to the archive/CI-badge overlap fix per instructions:
- Traced the CSS/HTML change directly: `.card-archive` moved from `.card-head` (`position: absolute; top: 50%; right: 8px`) into `.card-body` as the first child, now `float: right; margin: 0 0 4px 8px`, `.card-title` (a sibling `<p>`) follows it in DOM order so text wraps around the float. `.ci-run-btn` shrunk to an 18x18 icon-only button (text `▶ Run` -> `▶`), reducing `.card-head` density. The old `:has()` hide-on-hover band-aid rule was cleanly removed with no dangling references left (grepped `card-archive`/`ci-run-btn`/`:has` across the file — only the new rules remain).
- Ran the live app (`server.py` on :8423, already running) and used a scratch Playwright script to get real bounding boxes for the `t-200b` card (closed, `ci: true`) in both themes, hovering to reveal `.card-archive`. Raw bbox overlap of `.card-archive` vs `.card-title`'s paragraph box reported `true`, but that is an artifact of the paragraph's box spanning full container width even though the float pulls the archive button out of flow — not a text-glyph collision. Used `Range.getClientRects()` on the title's actual text nodes to get real per-line glyph rects: line 1 ends at x=1046.3, `.card-archive` starts at x=1097.3 (51px clear gap); line 2 sits below `.card-archive`'s bottom edge entirely. No `.card-archive`/`.ci-run-btn`/`.ci-badge` overlaps in either theme. Screenshot of the hovered card confirms this visually (title wraps cleanly around the pill-shaped archive button, header row shows COPY/TASK/CI/▶ with no crowding). This is a genuine fix, not a band-aid — the element left the competing flow container entirely rather than being resized/repositioned within it.
- Confirmed no id/class was removed or renamed: `.card-archive`, `.ci-run-btn`, `.ci-badge` class names all unchanged; only their container/content/size changed. One new `aria-label` attribute added (additive). `tests/sprint-check-app.spec.js` selectors for these classes are unaffected (grepped — no test asserts on DOM position or button text content).
- Confirmed the float doesn't break `.card-body`'s layout: a clearfix was added (`.card-body::after { content:''; display:table; clear:both; }`), and the rendered screenshot shows `.card-footer` (age/priority/status) sitting correctly below the title/archive row with no visual collapse.

Modal doc-content styling (`.doc-heading-2`, `.section-jump-link`) checked for consistency with the rest of the diff: `.doc-heading-2` now uses uppercase/weight 750/tracking .06em/bottom-border, matching the same treatment applied to `.column-title` elsewhere in this diff. `.section-jump-link` becomes a pill shape (`border-radius: 999px`, padding, transparent border until hover) — structurally modeled on `.doc-tab` (also `border-radius: 999px`) though `.doc-tab` shows a visible border at rest while `.section-jump-link` only reveals its border/background on hover; this is a minor, plausibly intentional weight difference between a primary tab control and a secondary in-doc nav affordance, not a defect — rendered screenshot of the ticket modal confirms both read as a coherent, uppercased, chip-like nav row.

Ran the full `npm run test:ui` suite directly (not just trusting plan.md's claim): 36/37 passed. The one failure (`markdown syntax shown as an inline-code example...`) reproduced passing cleanly when re-run in isolation — matches the exact pre-existing flake documented in `acceptance.md`/`plan.md`, not caused by this diff. Grepped the diff for `@import`/`url(http`/`@font-face` — no matches, no new external dependency.

No scope creep, dead code, unnecessary complexity, or standards violations found. The one added CSS comment (explaining why `.card-archive` moved) documents non-obvious root-cause reasoning per `standards/efficiency.md`'s "no comments unless the WHY is non-obvious" — acceptable. The stale comment explaining the removed `:has()` hover-hide rule was deleted along with the rule, so no orphaned comment was left behind.

## Verdict

YES
