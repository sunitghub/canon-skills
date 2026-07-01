#!/usr/bin/env python3
"""Convert a plain-text outline into a first-pass PPTX using the Octave POTX template.

Outline format (markdown-like):
  # Deck Title
  ## Section Name
  A section header slide (no bullets under it).
  ## Slide Title
  - bullet one
  - bullet two

Usage:
  python3 text_to_pptx.py <outline.txt> <output.pptx>
"""
import sys
import zipfile
from pathlib import Path

from pptx import Presentation

ASSET = Path(__file__).parent.parent / "assets" / "PowerPoint" / "Octave_PPT_Template_20260401.potx"

TEMPLATE_CT = b"application/vnd.openxmlformats-officedocument.presentationml.template.main+xml"
PRESENTATION_CT = b"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"


def load_template(potx_path: Path, tmp_pptx: Path) -> Presentation:
    """python-pptx refuses .potx directly (content type is 'template', not
    'presentation'). Patch [Content_Types].xml so it opens as a normal deck."""
    with zipfile.ZipFile(potx_path) as zin:
        with zipfile.ZipFile(tmp_pptx, "w", zipfile.ZIP_DEFLATED) as zout:
            for name in zin.namelist():
                data = zin.read(name)
                if name == "[Content_Types].xml":
                    data = data.replace(TEMPLATE_CT, PRESENTATION_CT)
                zout.writestr(name, data)
    return Presentation(tmp_pptx)


def strip_example_slides(prs: Presentation) -> None:
    """The POTX ships 75 pre-built example slides (one per layout) as a
    gallery. Every generated deck must start empty, or the user's content
    gets appended after the entire example gallery."""
    sld_id_lst = prs.slides._sldIdLst
    for sld_id in list(sld_id_lst):
        r_id = sld_id.get(
            "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
        )
        prs.part.drop_rel(r_id)
        sld_id_lst.remove(sld_id)


def parse_outline(text: str):
    """Returns (title, sections). Each section is
    (heading, bullets: list[str], is_section_header: bool)."""
    lines = [ln.rstrip() for ln in text.splitlines() if ln.strip()]
    if not lines or not lines[0].startswith("# "):
        raise ValueError("Outline must start with '# Deck Title'")
    title = lines[0][2:].strip()

    sections = []
    heading = None
    bullets = []
    for line in lines[1:]:
        if line.startswith("## "):
            if heading is not None:
                sections.append((heading, bullets, len(bullets) == 0))
            heading = line[3:].strip()
            bullets = []
        elif line.startswith("- "):
            bullets.append(line[2:].strip())
    if heading is not None:
        sections.append((heading, bullets, len(bullets) == 0))

    return title, sections


def build_pptx(outline_text: str, output_path: Path) -> None:
    tmp_pptx = output_path.with_suffix(".base.pptx")
    prs = load_template(ASSET, tmp_pptx)
    strip_example_slides(prs)

    layouts = {layout.name: layout for layout in prs.slide_masters[0].slide_layouts}
    title, sections = parse_outline(outline_text)

    title_slide = prs.slides.add_slide(layouts["Title Slide"])
    title_slide.placeholders[0].text = title

    for heading, bullets, is_section_header in sections:
        if is_section_header:
            slide = prs.slides.add_slide(layouts["Section Header"])
            slide.placeholders[0].text = heading
            continue

        slide = prs.slides.add_slide(layouts["Title and Content"])
        slide.placeholders[0].text = heading
        body = slide.placeholders[1].text_frame
        body.text = bullets[0]
        for bullet in bullets[1:]:
            p = body.add_paragraph()
            p.text = bullet

    prs.save(output_path)
    tmp_pptx.unlink(missing_ok=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: text_to_pptx.py <outline.txt> <output.pptx>", file=sys.stderr)
        sys.exit(1)
    outline_path, out_path = Path(sys.argv[1]), Path(sys.argv[2])
    build_pptx(outline_path.read_text(), out_path)
    print(f"Wrote {out_path}")
