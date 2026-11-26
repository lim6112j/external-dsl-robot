#!/usr/bin/env python3
"""Convert a markdown file to a .docx using python-docx.

Written for this repository's patent specification, but kept general: headings,
paragraphs, bold / italic / inline code, bullet and numbered lists, pipe tables,
fenced code blocks, block quotes and horizontal rules. Korean text is expected,
so the default fonts are set explicitly on the Normal and code styles rather
than left to the locale default.

Usage:
    python3 tools/md2docx.py docs/PATENT-ROBOT-DSL-INTEGRATION.md
    python3 tools/md2docx.py in.md -o out.docx

python-docx is not part of the Haskell build; it is a documentation-time
dependency, like pandoc.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor

BODY_FONT = "Malgun Gothic"
MONO_FONT = "Consolas"


def set_east_asian(style, font_name: str) -> None:
    """python-docx only sets w:ascii/w:hAnsi; Korean needs w:eastAsia too."""
    rpr = style.element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = rpr.makeelement(qn("w:rFonts"), {})
        rpr.append(rfonts)
    rfonts.set(qn("w:eastAsia"), font_name)


def configure_styles(doc: Document) -> None:
    normal = doc.styles["Normal"]
    normal.font.name = BODY_FONT
    normal.font.size = Pt(10)
    set_east_asian(normal, BODY_FONT)
    normal.paragraph_format.space_after = Pt(6)
    normal.paragraph_format.line_spacing = 1.25

    for name, size, color in (
        ("Title", 20, RGBColor(0x1F, 0x2A, 0x37)),
        ("Heading 1", 16, RGBColor(0x1F, 0x2A, 0x37)),
        ("Heading 2", 13, RGBColor(0x1F, 0x2A, 0x37)),
        ("Heading 3", 11.5, RGBColor(0x1F, 0x2A, 0x37)),
        ("Heading 4", 10.5, RGBColor(0x37, 0x41, 0x51)),
    ):
        style = doc.styles[name]
        style.font.name = BODY_FONT
        style.font.size = Pt(size)
        style.font.bold = True
        style.font.color.rgb = color
        set_east_asian(style, BODY_FONT)
        style.paragraph_format.space_before = Pt(10)
        style.paragraph_format.space_after = Pt(4)

    code = doc.styles["Code"] if "Code" in [s.name for s in doc.styles] else None
    if code is None:
        from docx.enum.style import WD_STYLE_TYPE

        code = doc.styles.add_style("Code", WD_STYLE_TYPE.PARAGRAPH)
        code.base_style = doc.styles["Normal"]
    code.font.name = MONO_FONT
    code.font.size = Pt(8.5)
    code.font.color.rgb = RGBColor(0x1B, 0x2B, 0x22)
    set_east_asian(code, MONO_FONT)
    code.paragraph_format.space_before = Pt(2)
    code.paragraph_format.space_after = Pt(2)
    code.paragraph_format.line_spacing = 1.0
    code.paragraph_format.left_indent = Pt(12)


# ---------------------------------------------------------------------------
# Inline markdown
# ---------------------------------------------------------------------------

INLINE = re.compile(
    r"(?P<bold>\*\*(?P<bold_text>.+?)\*\*)"
    r"|(?P<italic>(?<!\*)\*(?P<italic_text>[^*]+?)\*(?!\*))"
    r"|(?P<code>`(?P<code_text>[^`]+?)`)",
    re.DOTALL,
)


def add_runs(paragraph, text: str, base_bold: bool = False) -> None:
    """Append runs for one markdown paragraph body, honouring **bold** and `code`."""
    pos = 0
    for m in INLINE.finditer(text):
        if m.start() > pos:
            paragraph.add_run(text[pos : m.start()]).bold = base_bold
        if m.group("bold"):
            run = paragraph.add_run(m.group("bold_text"))
            run.bold = True
        elif m.group("italic"):
            run = paragraph.add_run(m.group("italic_text"))
            run.italic = True
        elif m.group("code"):
            run = paragraph.add_run(m.group("code_text"))
            run.font.name = MONO_FONT
            run.font.size = Pt(9)
        pos = m.end()
    if pos < len(text):
        paragraph.add_run(text[pos:]).bold = base_bold


# ---------------------------------------------------------------------------
# Block parsing
# ---------------------------------------------------------------------------

FENCE = re.compile(r"^\s*```")
HRULE = re.compile(r"^\s*(-{3,}|\*{3,}|_{3,})\s*$")
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
BULLET = re.compile(r"^(\s*)-\s+(.*)$")
ORDERED = re.compile(r"^(\s*)(\d+)\.\s+(.*)$")
BLOCKQUOTE = re.compile(r"^\s*>\s?(.*)$")
TABLE_SEP = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*$")


def split_row(line: str):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [c.strip() for c in line.split("|")]


def is_table_start(lines, i):
    if i + 1 >= len(lines) or "|" not in lines[i]:
        return False
    return bool(TABLE_SEP.match(lines[i + 1]))


def convert(md: str, out_path: Path) -> None:
    doc = Document()
    configure_styles(doc)
    section = doc.sections[0]
    section.left_margin = section.right_margin = Pt(56)

    lines = md.splitlines()
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]

        if not line.strip():
            i += 1
            continue

        # Fenced code block
        if FENCE.match(line):
            i += 1
            block = []
            while i < n and not FENCE.match(lines[i]):
                block.append(lines[i])
                i += 1
            i += 1  # closing fence
            for text in block:
                p = doc.add_paragraph(text if text else "", style="Code")
                p.paragraph_format.space_after = Pt(0)
            continue

        # Horizontal rule
        if HRULE.match(line):
            i += 1
            continue

        # Heading
        m = HEADING.match(line)
        if m:
            level = len(m.group(1))
            text = m.group(2).strip()
            if level == 1:
                doc.add_paragraph(text, style="Title")
            else:
                doc.add_paragraph(text, style=f"Heading {min(level - 1, 4)}")
            i += 1
            continue

        # Table
        if is_table_start(lines, i):
            header = split_row(lines[i])
            i += 2  # header + separator
            rows = []
            while i < n and lines[i].strip() and "|" in lines[i]:
                rows.append(split_row(lines[i]))
                i += 1
            table = doc.add_table(rows=1, cols=len(header))
            table.style = "Light Grid Accent 1"
            table.alignment = WD_TABLE_ALIGNMENT.CENTER
            for idx, cell in enumerate(header):
                cell_par = table.rows[0].cells[idx].paragraphs[0]
                cell_par.paragraph_format.space_after = Pt(2)
                run = cell_par.add_run(cell)
                run.bold = True
                run.font.size = Pt(9)
            for row in rows:
                cells = table.add_row().cells
                for idx in range(len(header)):
                    value = row[idx] if idx < len(row) else ""
                    par = cells[idx].paragraphs[0]
                    par.paragraph_format.space_after = Pt(2)
                    add_runs(par, value)
                    for run in par.runs:
                        run.font.size = Pt(9)
            doc.add_paragraph()
            continue

        # Bullet list
        m = BULLET.match(line)
        if m:
            indent = len(m.group(1).expandtabs(4)) // 2
            style = "List Bullet" if indent == 0 else "List Bullet 2"
            p = doc.add_paragraph(style=style)
            p.paragraph_format.space_after = Pt(3)
            add_runs(p, m.group(2).strip())
            i += 1
            continue

        # Ordered list
        m = ORDERED.match(line)
        if m:
            p = doc.add_paragraph(style="List Number")
            p.paragraph_format.space_after = Pt(3)
            add_runs(p, m.group(3).strip())
            i += 1
            continue

        # Block quote
        m = BLOCKQUOTE.match(line)
        if m:
            p = doc.add_paragraph()
            p.paragraph_format.left_indent = Pt(18)
            p.paragraph_format.space_after = Pt(6)
            add_runs(p, m.group(1).strip())
            for run in p.runs:
                run.font.size = Pt(9)
                run.italic = True
            i += 1
            continue

        # Plain paragraph: consume until a blank line or a block starter
        para = [line.rstrip()]
        i += 1
        while i < n and lines[i].strip():
            if (
                HEADING.match(lines[i])
                or BULLET.match(lines[i])
                or ORDERED.match(lines[i])
                or FENCE.match(lines[i])
                or HRULE.match(lines[i])
                or is_table_start(lines, i)
                or BLOCKQUOTE.match(lines[i])
            ):
                break
            para.append(lines[i].rstrip())
            i += 1
        p = doc.add_paragraph()
        add_runs(p, " ".join(x.strip() for x in para))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    doc.save(out_path)


def main() -> int:
    ap = argparse.ArgumentParser(description="Convert markdown to docx")
    ap.add_argument("input", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=None)
    args = ap.parse_args()

    if not args.input.is_file():
        print(f"error: no such file: {args.input}", file=sys.stderr)
        return 1

    out = args.out or args.input.with_suffix(".docx")
    convert(args.input.read_text(encoding="utf-8"), out)
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
