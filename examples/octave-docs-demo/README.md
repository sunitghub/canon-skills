# octave-docs demo: context-management

Shows `octave-docs` distilling an existing canon deck into a short, Octave-branded
first pass. Source: `posts/slides/context-management.md` — a 13-slide Marp deck with
heavy inline HTML/CSS (card grids, custom hero layouts).

`octave-docs` can't consume that file directly — it only understands a plain
`#`/`##`/`-` outline, mapped onto three real PowerPoint layouts (Title Slide, Section
Header, Title and Content). This demo distills the Marp deck's core content down to
that grammar: a 4-slide deck (title + 3 sections) and a matching 3-section memo.

This is necessarily lossy. Marp's custom visuals — the "200,000 tokens" big-number hero
slide, the token-budget card stack, the phase-pipeline diagram — have no equivalent in
Octave's layout set. What survives is the substance: the numbers, the argument, the
five rules. That tradeoff is the point of the demo, not a bug to fix.

## Files

- `deck-outline.txt` / `memo-outline.txt` — the distilled plain-text source
- `context-management-demo.pptx` / `.docx` — generated output

## Regenerate

```bash
python3 skills/octave-docs/scripts/text_to_pptx.py examples/octave-docs-demo/deck-outline.txt examples/octave-docs-demo/context-management-demo.pptx
python3 skills/octave-docs/scripts/text_to_docx.py examples/octave-docs-demo/memo-outline.txt examples/octave-docs-demo/context-management-demo.docx
```
