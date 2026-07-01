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
```
A `##` heading with no bullets under it becomes a **Section Header** slide; a `##`
heading with bullets becomes a **Title and Content** slide.

For a memo (`docx`):
```
# Memo Title
## Heading
Body paragraph text.
Another body paragraph.
```

**3. Write the outline** to a temp file, then run the matching script:

```bash
python3 skills/octave-docs/scripts/text_to_pptx.py <outline.txt> posts/octave-docs/<name>.pptx
python3 skills/octave-docs/scripts/text_to_docx.py <outline.txt> posts/octave-docs/<name>.docx
```

Create `posts/octave-docs/` if it doesn't exist.

**4. Verify the output** opens cleanly before reporting success:

```bash
python3 -c "from pptx import Presentation; Presentation('<output.pptx>')"
python3 -c "import docx; docx.Document('<output.docx>')"
```

**5. Report the output path** and remind the user this is a first pass — brand review
before external distribution is still on them.

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
