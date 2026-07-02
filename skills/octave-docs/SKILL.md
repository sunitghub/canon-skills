---
name: octave-docs
description: Converts a plain-text outline into a first-pass Octave-branded PPTX deck or DOCX memo using real Office templates. Use when asked for a first-pass PowerPoint deck, a text-to-PPT or text-to-Word conversion, or an Octave-branded slide deck or memo.
category: ops
tags: [office, pptx, docx, octave, templates]
argument-hint: "[pptx|docx]"
---

# octave-docs

Generates a first-pass Office file (PPTX or DOCX) from a plain-text outline, using
Octave's real branded templates — not an HTML/Marp render. Output is a genuine
PowerPoint/Word file the recipient can open and keep editing.

For canon-topic decks (context management, evaluator pattern, skill authoring), use
`canon-slides` instead — that skill covers a different pipeline (Marp/HTML/CSS) for a
different audience.

To install this skill in Claude Desktop or claude.ai instead of the canon repo, see
`references/claude-desktop-setup.md`.

## Usage

```
/octave-docs pptx   — write a deck outline, get back a .pptx
/octave-docs docx   — write a memo outline, get back a .docx
```

## Steps

**1. Check dependencies.** Run `python3 -c "import pptx, docx"`. If either import fails,
tell the user to run:

```
pip3 install python-pptx python-docx
```

Stop and wait — do not proceed without both libraries available.

**2. Get the outline from the user.** Ask for (or use if already provided) plain text in
this format:

For a deck (`pptx`):
```
# Deck Title
## Section Name
## Slide Title
- bullet one
- bullet two
## Table Slide
| Header One | Header Two |
| row one col a | row one col b |
```
A `##` heading with no bullets or table rows under it becomes a **Section Header** slide;
one with bullets becomes a **Title and Content** slide; one with `|`-delimited rows
becomes a **Title and Table** slide (first row is the header row). Don't mix bullets and
table rows under the same heading — pick one per section.

For a memo (`docx`):
```
# Memo Title
## Heading
Body paragraph text.
Another body paragraph.
```

**3. Write the outline** to a temp file, then run the matching script. Output goes to
`posts/octave-docs/<name>.pptx` (create the directory if it doesn't exist) when working
inside the canon repo; in a standalone environment with no `posts/` convention (e.g. a
Claude Desktop/claude.ai Skill upload — see `references/claude-desktop-setup.md`), write
to the current working directory instead.

```bash
python3 skills/octave-docs/scripts/text_to_pptx.py <outline.txt> <output.pptx>
python3 skills/octave-docs/scripts/text_to_docx.py <outline.txt> <output.docx>
```

**4. Verify the output** opens cleanly before reporting success:

```bash
python3 -c "from pptx import Presentation; Presentation('<output.pptx>')"
python3 -c "import docx; docx.Document('<output.docx>')"
```

**5. Report the output path** and remind the user this is a first pass — brand review
before external distribution is still on them.

See `examples/octave-docs-demo/` for a worked example: distilling an existing Marp deck
(`posts/slides/context-management.md`) into a short outline and generating both formats.

## Gotchas

- Both Octave templates ship as `.potx`/`.dotx` (template content type), which
  `python-pptx`/`python-docx` refuse to open directly. Both scripts patch
  `[Content_Types].xml` in-memory to the matching `presentation`/`document` content type
  before loading — this is already handled in `scripts/`, do not attempt to open the
  `.potx`/`.dotx` files directly with either library.
- The PPTX template (`Octave_PPT_Template_20260401.potx`) ships **75 pre-built example
  slides** (one per layout, as a gallery) — not an empty deck. `text_to_pptx.py` strips
  all of them before adding the outline's slides. If you ever load the raw template
  another way, you must strip existing slides first or the output will have the entire
  example gallery in front of the real content.
- The DOCX template (`Octave Memo_US.dotx`) ships example placeholder body copy
  ("Ipsapicita dolorest...") and a closing/signature block — `text_to_docx.py` clears the
  body before writing. The available named styles are `Heading 1 Memo`, `Heading 2`,
  `Body Text` (not `Heading 1` / `Normal`).
- Only the memo template is wired up. `Octave_Master-Editorial_A4_v8.dotx` (a longer
  report/style-guide template with cover pages and a TOC) exists in `assets/Word/` but has
  no script path yet — it's a heavier document shape than "first pass," out of scope here.
- The **Title and Table** layout has no table *placeholder* in the POTX — its own example
  slide adds the table as a free-floating shape at a fixed position/size. `text_to_pptx.py`
  replicates that exact position (`TABLE_POSITION`/`TABLE_SIZE`), and manually sets the
  table's `tableStyleId` to Octave's registered brand style via raw XML, since python-pptx
  has no public API for applying a specific registered table style. The table is always
  sized to that fixed region regardless of row/column count — a very large table can
  overflow it; this is first-pass scope, not dynamic layout.
