---
name: canon-slides
description: Generates Marp slide decks from canon knowledge. Use when asked to create slides, build a presentation, or generate a deck on a canon topic (context management, evaluator pattern, or skill authoring). Renders to HTML — opens in any browser with no Office dependency.
category: ops
tags: [slides, marp, presentations, knowledge]
argument-hint: "[topic] [--theme canon|octave]"
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

**3. Write `slides/<topic>.md`.** Create the file with this header:

```markdown
---
marp: true
theme: canon
paginate: true
---
```

Replace `canon` with `octave` when `--theme octave` is passed.

Structure the deck as follows — use your judgment on the exact slide copy, but follow this outline:

- **Title slide** — topic title + one-line summary of the core insight
- **Problem / Why this matters** — what goes wrong without this pattern (1–2 slides)
- **Core pattern** — the key concept explained clearly (2–3 slides)
- **Canon implementation** — how canon handles this concretely, with specific examples from the source files (2–3 slides)
- **Gotchas / What to watch for** — failure modes and non-obvious constraints (1 slide)
- **Summary** — one slide, 3–5 bullet takeaways

Guidelines for slide copy:
- Active voice, short sentences. Each slide has one point.
- Code blocks use fenced ` ``` ` — Marp renders them with syntax highlighting.
- Prefer concrete examples over abstract principles.
- Marp slide separator is `---` on its own line. Do not skip it between slides.

**4. Render to HTML.** Run this exact command:

```bash
npx @marp-team/marp-cli slides/<topic>.md \
  --theme skills/canon-slides/themes/<theme>.css \
  -o slides/<topic>.html \
  --allow-local-files
```

Where `<theme>` is `canon` or `octave`.

If `npx` is not available or marp-cli fails, stop and tell the user:
```
marp-cli not found. Install with: npm install -g @marp-team/marp-cli
Then rerun: npx @marp-team/marp-cli slides/<topic>.md --theme skills/canon-slides/themes/<theme>.css -o slides/<topic>.html
```

**5. Report output.** On success, tell the user:
- Path to the `.md` source: `slides/<topic>.md`
- Path to the HTML: `slides/<topic>.html`
- How to open: `open slides/<topic>.html` (macOS) or just open it in any browser

## Octave theme — logo slot

`themes/octave.css` has a `--logo-url` variable. To add your logo once you have an SVG/PNG:

```css
/* In themes/octave.css, replace: */
--logo-url: none;
/* With: */
--logo-url: url('/path/to/octave-logo.svg');
```

Or pass it per-render:
```bash
npx @marp-team/marp-cli slides/<topic>.md --theme themes/octave.css \
  --css "section { --logo-url: url('/abs/path/to/logo.svg'); }" \
  -o slides/<topic>.html
```

## Gotchas

- Marp's `---` separators are load-bearing — they create slide breaks. Do not remove them when editing the `.md` source.
- The `--allow-local-files` flag is required for CSS themes referenced by local path; without it, marp-cli silently ignores the theme.
- The `theme:` value in the deck's frontmatter must match the theme name declared in the CSS (`/* @theme canon */`). Mismatch causes marp-cli to fall back to default styling.
- Run the render command from the repo root so relative paths to `skills/canon-slides/themes/` resolve correctly.
- If the deck opens blank in the browser, check the browser console — Content Security Policy on some browsers blocks local file CSS. Use `file://` URL or `open` on macOS.
