---
name: canon-slides
description: Generates Marp slide decks from canon knowledge. Use when asked to create slides, build a presentation, or generate a deck on a canon topic (context management, evaluator pattern, or skill authoring). Renders to HTML — opens in any browser with no Office dependency.
category: ops
tags: [slides, marp, presentations, knowledge]
argument-hint: "[topic] [--theme canon|octave]"
hidden: true
---

# canon-slides

Generates a Marp slide deck from canon source files and renders it to HTML.

## Usage

```
/canon-slides <topic> [--theme canon|octave]
```

**Topics:**

| Slug | What it covers |
|---|---|
| `context-management` | Token efficiency, always-on vs on-demand loading, context bloat patterns |
| `evaluator-pattern` | Generator-evaluator separation, clean context eval, avoiding self-grading |
| `skill-authoring` | Skill structure, description quality, eval coverage, gotchas pattern |

Default theme: `canon`. Pass `--theme octave` for Octave brand styling.

## Steps

**1. Parse arguments.** Extract topic slug and theme from `$ARGUMENTS`. If the topic is not one of the three above, stop and list the valid options.

**2. Read source files for the topic.**

For `context-management`, read:
- `standards/efficiency.md` (Token Efficiency section)
- `skills/context-check/SKILL.md`
- `skills/sprint/SKILL.md` (the always-on vs on-demand loading distinction)

For `evaluator-pattern`, read:
- `skills/sprint/reference/eval.md`
- `skills/skill-eval/SKILL.md`
- `DECISIONS.md` (entries mentioning "evaluator", "generator-evaluator", or "clean context")

For `skill-authoring`, read:
- `standards/skill-setup-std.md`
- `guides/skill-authoring.md`
- `skills/skill-eval/SKILL.md` (the evals and testing section)

**2b. Check for applicable partials.** Before writing slides, read `skills/canon-slides/partials/` and list available partials. If a partial fits the deck's topic or audience, read it and insert it verbatim at the appropriate position — do not rewrite or inline its content by hand.

| Partial | When to include |
|---|---|
| `worthwhile-harness.md` | Any intro or pitch deck where the audience needs to understand what a harness must do before seeing canon specifically. Insert after the problem slide, before the canon overview. |

Marp has no native include syntax. The DRY contract is: **edit partials, not decks**. If a slide in a deck was sourced from a partial, add a HTML comment above it: `<!-- partial: worthwhile-harness.md -->`. Future edits go to the partial; the deck is regenerated.

**3. Write `posts/slides/<topic>.md`.** Create the file with this header:

```markdown
---
marp: true
theme: canon
paginate: true
html: true
---
```

Replace `canon` with `octave` when `--theme octave` is passed. `html: true` is required — without it, all `<div>` styling is stripped by Marp.

Immediately after the frontmatter, add a global animation block (before the title slide):

```html
<style>
@keyframes fadeUp {
  from { opacity: 0; transform: translateY(16px); }
  to   { opacity: 1; transform: translateY(0); }
}
.card { animation: fadeUp 0.35s both; }
.c1 { animation-delay: 0.05s; } .c2 { animation-delay: 0.22s; }
.c3 { animation-delay: 0.39s; } .c4 { animation-delay: 0.56s; }
.c5 { animation-delay: 0.73s; }
.step { animation: fadeUp 0.3s both; }
.s1 { animation-delay: 0.05s; } .s2 { animation-delay: 0.18s; }
.s3 { animation-delay: 0.31s; } .s4 { animation-delay: 0.44s; }
.s5 { animation-delay: 0.57s; }
</style>
```

Assign `.card .cN` to each card in a set so they stagger in on load. Assign `.step .sN` to sequential row items (flow diagrams, timeline bars, etc.).

**Space-filling — every slide uses a 3-row layout: heading / body / footer.**

The section is `display:flex; flex-direction:column; justify-content:flex-start` with `padding: 52px 72px 64px` on a 720px canvas. **Never use `height:X%` on body containers** — percentage resolution against a flex container's padded size is browser-dependent and clips footers. Instead, use `flex:1; min-height:0` on the direct child of the section (the body container). This fills exactly the remaining space after the h2 with no percentage guessing needed.

**Single source of truth — use this pattern every time, without modification:**

```html
<!-- Body only (no footer) -->
<div style="display:flex; flex-direction:column; flex:1; min-height:0; gap:12px;">
  <!-- cards, diagrams, etc -->
</div>

<!-- Body + footer (callout / caption) -->
<div style="display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:10px;">
  <div style="display:flex; gap:14px; min-height:0;">
    <!-- body content — min-height:0 required so 1fr grid row is actually respected -->
  </div>
  <div style="padding:10px 16px; background:rgba(62,64,71,0.3); border-left:3px solid #00FFFF; border-radius:0 8px 8px 0; font-size:0.8em; color:#B2B8C4;">
    Footer callout text here.
  </div>
</div>

<!-- Title / big-number hook (no h2 above it) -->
<div style="display:flex; flex-direction:column; justify-content:center; flex:1; min-height:0; gap:24px;">
  <!-- centred content -->
</div>
```

**Font-size scaling rule.** When a slide has dense content (4+ cards, code blocks + fix rows, or stacked diagrams), reduce font sizes proportionally rather than letting content overflow. Standard scale-down step:

| Content density | Card padding | Body text | Code text | Badge |
|---|---|---|---|---|
| Normal (2–3 items) | `16px 18px` | `0.76em` | `0.65em` | `28px` |
| Dense (4 items + fix rows) | `12px 14px` | `0.68em` | `0.60em` | `22px` |
| Very dense (6+ items) | `10px 12px` | `0.62em` | `0.56em` | `18px` |

Reduce gap between cards accordingly: `gap:14px` → `gap:10px` → `gap:8px`. Never clip or overflow — scale down first.

**Cards containing code blocks (`<pre>` inside a card column):** The body row flex container MUST have `min-height:0`, and each card MUST have `min-height:0; overflow:hidden`. Without these, grid's `1fr` allocation is ignored and cards overflow into the footer. The `<pre>` inside the card gets `flex:1; overflow:hidden` so it fills but doesn't burst past the card boundary. Also drop stat numbers from `1.6em` → `1.3em` and body text from `0.76em` → `0.72em` to recover vertical space.

Rules:
1. **`flex:1; min-height:0`** on every outer body container — no exceptions, no `height:X%`.
2. Inside the body div, use `flex:1` on expanding children — never hardcode `height:Npx` on layout containers.
3. Column layouts use `display:flex; align-items:stretch` (not `align-items:center`) with `flex:1` columns so they fill the available height.
4. Footer callouts use `grid-template-rows:1fr auto` — `auto` guarantees the footer its natural height; `1fr` gives the body the rest.
5. Never put the footer outside the `flex:1` container (orphaned elements render in a tiny strip below the content area).

Quick reference:

| Slide type | Outer container |
|---|---|
| Body + footer callout | `display:grid; grid-template-rows:1fr auto; flex:1; min-height:0; gap:10px` |
| Side-by-side columns | `display:flex; align-items:stretch; flex:1; min-height:0; gap:20px` |
| 2-column card grid | `display:grid; grid-template-columns:1fr 1fr; flex:1; min-height:0; gap:16px` |
| Vertical card list | `display:flex; flex-direction:column; flex:1; min-height:0; gap:12px` |
| Flow/pipeline | `display:flex; flex-direction:column; align-items:center; flex:1; min-height:0` |
| Title / hook (no h2) | `display:flex; flex-direction:column; justify-content:center; flex:1; min-height:0` |

**Orphan check — no elements outside the flex container.** After writing each slide, verify that every visible element (blockquotes, captions, footnotes, closing remarks) lives *inside* the `flex:1; min-height:0` body container — not after the closing `</div>`. Elements placed after the container render wherever remaining space allows, typically a tiny strip near the bottom. The pattern to avoid:

```html
<!-- ✗ Wrong: caption is orphaned outside the body container -->
<div style="flex:1; min-height:0; display:flex; ...">
  <div>big content</div>
</div>
<div style="font-size:0.85em; color:#6F7480;">caption here</div>

<!-- ✓ Right: caption inside, full layout owned by one container -->
<div style="display:flex; flex-direction:column; justify-content:center; flex:1; min-height:0; gap:28px;">
  <div>big content</div>
  <div style="font-size:0.85em; color:#6F7480; text-align:center;">caption here</div>
</div>
```

For "big number + caption" hook slides specifically: use `display:flex; flex-direction:column; justify-content:center; align-items:center; flex:1; min-height:0; gap:28px` with both the number and its caption as direct children — this keeps them vertically centred together as a unit.

**Slide structure** — target 15–20 slides for a 20–30 min talk (~90 s/slide):

- **Title slide** — never use bare `# Heading` + paragraph for the title slide. It renders top-left with huge empty space below. Use a full-height centered HTML layout instead:

```html
<div style="display:flex; flex-direction:column; justify-content:center; flex:1; min-height:0; gap:24px;">
<div style="display:flex; flex-direction:column; gap:16px;">
<div style="font-size:3.2em; font-weight:900; line-height:1.1; color:#FFFFFF; letter-spacing:-0.02em;">Deck Title Here</div>
<div style="width:72px; height:4px; background:linear-gradient(90deg,#00FFFF,#4FFF00); border-radius:2px;"></div>
<div style="font-size:1.15em; color:#00FFFF; font-weight:400; line-height:1.5;">One-line hook subtitle goes here — no max-width, no &lt;br&gt;</div>
</div>
</div>
```

- **Hook / thought experiment** — concrete scenario before any jargon (1 slide)
- **Problem / Why this matters** — what goes wrong without this pattern (1–2 slides)
- **Core pattern** — the key concept explained clearly (2–3 slides)
- **Canon implementation** — how canon handles this concretely, with specific examples from the source files (2–3 slides)
- **Gotchas / What to watch for** — failure modes and non-obvious constraints (1 slide)
- **Summary** — one slide, 3–5 bullet takeaways
- **Q&A / Try it** — one slide with a concrete next action

**Visual design rules (learned from Octave AI Happy Hour decks):**

*Bullet lists → card grids.* Never use bare `<ul>` for key points. Use a card grid instead:
```html
<div style="display:flex; flex-direction:column; gap:12px; margin-top:16px;">
  <div class="card c1" style="display:flex; gap:18px; align-items:center; padding:14px 20px;
    background:rgba(62,64,71,0.35); border-radius:10px; border-left:4px solid #00FFFF;">
    <div style="font-size:1.5em; font-weight:800; color:#00FFFF; min-width:28px; flex-shrink:0;">1</div>
    <div style="font-size:0.88em; line-height:1.45;"><strong>Rule text here</strong> — explanation</div>
  </div>
  <!-- repeat with .c2, .c3 and rotate accent colors: #4FFF00 #FFF500 #F46600 #FF00C7 -->
</div>
```

*Two-column comparisons.* Use bordered columns with a colored header strip:
```html
<div style="flex:1; display:flex; flex-direction:column; border-radius:10px; overflow:hidden; border:1px solid rgba(0,255,255,0.25);">
  <div style="padding:12px 18px; background:rgba(0,255,255,0.15); font-size:0.68em;
    text-transform:uppercase; letter-spacing:0.09em; color:#00FFFF; font-weight:600;">Label</div>
  <div style="flex:1; padding:16px; background:rgba(62,64,71,0.25);">content</div>
</div>
```

*Diagrams (context window, stacks, timelines).* The diagram column must be at least `width:260px` — narrow columns look decorative, not informative. Box labels at `font-size:0.72em`, numbers/token counts at `font-size:1em; font-weight:800`. The "smart zone" box uses `flex:1` so it fills available height. Bottom reserved-area boxes show the number left-aligned in bold and the label right-aligned. Use `justify-content:space-between` when the number and label are on opposite sides; use `margin-left:8px` when they sit adjacent (otherwise Marp collapses them together with no gap):
```html
<!-- number left, label right (space-between) -->
<div style="padding:11px 16px; border-radius:4px; display:flex; justify-content:space-between; align-items:center;
  background:rgba(244,102,0,0.22); border:1px solid #F46600;">
  <span style="font-size:1em; font-weight:800; color:#F46600;">~33k</span>
  <span style="font-size:0.68em; color:#F46600;">compaction reserve</span>
</div>

<!-- number + label adjacent (use margin-left, not space-between) -->
<div style="padding:11px 16px; border-radius:4px; display:flex; align-items:center;
  background:rgba(244,102,0,0.22); border:1px solid #F46600;">
  <span style="font-size:1em; font-weight:800; color:#F46600;">~33k</span>
  <span style="font-size:0.68em; color:#F46600; margin-left:8px;">compaction reserve</span>
</div>
```

**Claude Code context window constants** (use these numbers in any context-management diagram):
- Total window: **200k** tokens
- Output reserve: **32k** (deduct from total → 168k input budget)
- Compaction reserve: **~33k** (triggers at ~167k / 83% of window)
- System prompt baseline: **~14k** (system instructions + built-in tool definitions, no CLAUDE.md)
- MCP schema cost: **5–10k per server** (loads every session whether called or not)
- Cache reads: save cost (10% of base price) but **still consume window space**

*SVG arrows in pipelines.* Use inline SVG for colored arrows — never plain text `→` or `↓` for diagrams that need visual weight:
```html
<svg width="20" height="20" viewBox="0 0 20 20">
  <path d="M10 2 L10 14 M4 10 L10 16 L16 10"
    stroke="#00FFFF" stroke-width="2" fill="none"
    stroke-linecap="round" stroke-linejoin="round"/>
</svg>
```
Never use `<linearGradient>` inside `<defs>` — Marp's parser breaks on `<stop>` tags and renders subsequent HTML as raw source.

*SVG diagonal leader lines (callout annotations).* Use when a label needs to point at the vertical midpoint of a tall diagram. Two diagonal lines converge from top-left and bottom-left to a horizontal tick, with the label to the right. The SVG uses `preserveAspectRatio="none"` with a 0-100 viewBox and `vector-effect="non-scaling-stroke"` to keep line weight consistent regardless of actual container dimensions:
```html
<div style="position:relative; flex:1; font-size:0.78em; color:#6F7480;">
  <svg style="position:absolute; top:0; left:0; width:100%; height:100%;"
       viewBox="0 0 100 100" preserveAspectRatio="none">
    <line x1="2" y1="0"   x2="38" y2="50" stroke="#00FFFF" stroke-width="1.5" vector-effect="non-scaling-stroke" stroke-linecap="round"/>
    <line x1="2" y1="100" x2="38" y2="50" stroke="#00FFFF" stroke-width="1.5" vector-effect="non-scaling-stroke" stroke-linecap="round"/>
    <line x1="38" y1="50" x2="52" y2="50" stroke="#00FFFF" stroke-width="1.5" vector-effect="non-scaling-stroke"/>
  </svg>
  <!-- top-right anchor -->
  <div style="position:absolute; top:0; right:0; color:#B2B8C4; font-weight:600;">top label</div>
  <!-- centre label — positioned just right of the tick (left:55%) -->
  <div style="position:absolute; top:50%; left:55%; transform:translateY(-50%);">
    <div style="font-size:1.8em; font-weight:800; color:#00FFFF; line-height:1;">168k</div>
    <div style="font-size:0.82em; color:#00FFFF;">tokens</div>
  </div>
  <!-- bottom-right anchor -->
  <div style="position:absolute; bottom:0; right:0; text-align:right;">bottom label</div>
</div>
```

*Cards with a level badge (L1 / L2 / L3, numbered, lettered).* Never use a fixed `width:Xpx` column for a badge that also has a sublabel (`Deterministic`, `Behavioural`, etc.) — at Marp's scaled font size the text overflows into adjacent columns. Put the sublabel inline with the title instead:
```html
<div style="font-size:1.6em; font-weight:800; color:#00FFFF; flex-shrink:0; min-width:36px; text-align:center;">L1</div>
<div style="flex:1;">
  <div style="display:flex; align-items:baseline; gap:10px; margin-bottom:4px;">
    <span style="font-size:0.85em; font-weight:700; color:#00FFFF;">Title</span>
    <span style="font-size:0.6em; color:#6F7480; text-transform:uppercase; letter-spacing:0.06em;">Sublabel</span>
  </div>
  <div style="font-size:0.78em; color:#B2B8C4; line-height:1.5;">Description</div>
</div>
```

*Weak-evidence / checklist rows.* Each item in its own box (not a bare `<li>`):
```html
<div class="card c1" style="display:flex; gap:14px; align-items:center; padding:13px 18px;
  background:rgba(244,102,0,0.08); border-radius:8px; font-size:0.82em;">
  <span style="color:#F46600; font-size:1.2em; flex-shrink:0;">✗</span>
  <span>item text</span>
</div>
```

Guidelines for slide copy:
- Active voice, short sentences. Each slide has one point.
- Code blocks use fenced ` ``` ` — Marp renders them with syntax highlighting.
- Prefer concrete examples over abstract principles.
- Marp slide separator is `---` on its own line. Do not skip it between slides.

**4. Render to HTML.** Run this exact command — `--html` is mandatory:

```bash
npx @marp-team/marp-cli posts/slides/<topic>.md \
  --theme skills/canon-slides/themes/<theme>.css \
  -o posts/slides/<topic>.html \
  --allow-local-files \
  --html
```

Where `<theme>` is `canon` or `octave`. Omitting `--html` silently strips all `<div>` styling and the slides render as plain text.

If `npx` is not available or marp-cli fails, stop and tell the user:
```
marp-cli not found. Install with: npm install -g @marp-team/marp-cli
Then rerun: npx @marp-team/marp-cli posts/slides/<topic>.md --theme skills/canon-slides/themes/<theme>.css -o posts/slides/<topic>.html --html
```

**5. Report output.** On success, tell the user:
- Path to the `.md` source: `posts/slides/<topic>.md`
- Path to the HTML: `posts/slides/<topic>.html`
- How to open: `open posts/slides/<topic>.html` (macOS) or just open it in any browser

## Octave theme — baked-in brand frame

`themes/octave.css` includes the Octave Pulse brand frame by default:
- top-right `Octave-White-Logo.png` mark
- bottom-right `OctavePulse_SitePage_Banner1-large.png` pulse background art
- dark overlay tuned for readability
- bottom rainbow accent bar

Do not add per-deck `section { background: ... }` or logo CSS for Octave decks unless the user explicitly asks for a one-off override. The theme is the source of truth.

The default asset references are relative to `posts/slides/<topic>.html`, so the assets must live in `posts/slides/`:
- `posts/slides/Octave-White-Logo.png`
- `posts/slides/OctavePulse_SitePage_Banner1-large.png`

Override only through theme variables in `themes/octave.css`:
- `--logo-url`
- `--background-art-url`
- `--background-art-size`
- `--background-art-position`
- `--background-overlay`

## Reserved zone — page counter

The page counter (`section::after`) is positioned at **`bottom: 16px; right: 48px`** of the section. It renders at roughly **60 px wide × 18 px tall** at `font-size: 0.5em`. This puts it at approximately `x: 1136–1232 px, y: 686–704 px` on the 1280×720 canvas.

**Never place content in the bottom-right corner of a slide.** The safe boundary is: keep content above `bottom: 48px` and left of `right: 120px` relative to the section. Absolute-positioned elements anchored to `bottom:0; right:0` of a content container will collide with the counter.

The page counter is in the bottom padding area (below the 604 px content zone), so flex/grid body content won't collide — only `position:absolute` elements with low `bottom` values can reach it.

## Gotchas

- **Never embed images as base64 data URIs in slide HTML.** Large base64 `src` values cause GPU compositing artifacts: the browser caches the first slide's compositor layer and bleeds it through every subsequent slide. The first slide appears ghosted behind all others. Always use file references (`<img src="./filename.png">`) and place images in `posts/slides/` alongside the HTML. The `--allow-local-files` flag is already required for the theme, so local image refs work without extra flags.
- **No blank lines inside HTML blocks.** Marp's markdown parser (markdown-it) exits HTML-block mode at the first blank line. Any content after a blank line inside a `<div>` structure is re-parsed as markdown — so a 4-space-indented `<div>` after a blank line becomes a code block displaying raw HTML source. Rule: once you open a `<div>`, write all child tags continuously with no blank lines between them until the outermost closing `</div>`. Use a single blank line only between top-level slide elements (markdown headings, paragraphs, and top-level HTML blocks).
- **Never use SVG `<defs>` or `<linearGradient>` inside slide HTML.** Marp's parser breaks on `<stop style="...">` tags inside `<defs>`, rendering all subsequent HTML in that slide as raw source code in a code block. Use a single solid stroke color for SVG arrows instead — gradients are not worth the parse failure.
- **`--html` is not optional.** Omitting it from the marp-cli command silently strips all `<div>` and `<style>` blocks — slides render as plain unstyled text even though `html: true` is in the frontmatter. Always pass both.
- **`html: true` in frontmatter alone is not enough** — the CLI flag and frontmatter key must both be set.
- **Diagram column width ≥ 260px.** Narrower columns make the context-window and stack diagrams look decorative rather than readable. Use `width:260px; flex-shrink:0` for diagram columns.
- **Numbered card sizes.** Large number labels (`font-size:1.5em; font-weight:800`) read clearly in a 1280×720 viewport. Anything smaller at `0.7em` or below disappears in a projector room.
- Marp's `---` separators are load-bearing — they create slide breaks. Do not remove them when editing the `.md` source.
- The `--allow-local-files` flag is required for CSS themes referenced by local path; without it, marp-cli silently ignores the theme.
- The `theme:` value in the deck's frontmatter must match the theme name declared in the CSS (`/* @theme canon */`). Mismatch causes marp-cli to fall back to default styling.
- Run the render command from the repo root so relative paths to `skills/canon-slides/themes/` resolve correctly.
- If the deck opens blank in the browser, check the browser console — Content Security Policy on some browsers blocks local file CSS. Use `file://` URL or `open` on macOS.
