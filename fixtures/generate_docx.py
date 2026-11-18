#!/usr/bin/env python3
"""Generate the DOCX fixtures of the runtime proof.

The engine's LibreOffice-backed conversion is exercised on two Word documents:
a one-page file and a fifty-page file. Both carry the same canary string, and
the fifty-page file names its page in each page's first line, so the output
check can prove pagination, not only that a PDF came back.

The files are written with the standard library only and with fixed zip
timestamps, so the bytes are reproducible: `--check` re-renders and compares.

Usage: generate_docx.py [DIR]
       generate_docx.py --check [DIR]
Exit: 0 written (or identical), 1 --check found a difference, 2 a prerequisite.
"""

from __future__ import annotations

import argparse
import sys
import zipfile
from pathlib import Path

CANARY = "STIRLING-CORE-CANARY"
FIXED_DATE = (2026, 11, 18, 0, 0, 0)

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
"""

RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
"""

PAGE_BREAK = '<w:p><w:r><w:br w:type="page"/></w:r></w:p>'


def paragraph(text: str, bold: bool = False) -> str:
    run = (
        f'<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">{text}</w:t></w:r>'
        if bold else
        f'<w:r><w:t xml:space="preserve">{text}</w:t></w:r>'
    )
    return f"<w:p>{run}</w:p>"


def document(pages: int) -> str:
    body: list[str] = []
    for page in range(1, pages + 1):
        body.append(paragraph(f"{CANARY} — page {page} of {pages}", bold=True))
        body.append(paragraph(
            "This page proves the LibreOffice conversion path of the MIT core PDF "
            "runtime: a Word document goes in, a PDF comes out."
        ))
        body.append(paragraph(
            f"An independent check reads the output's page count and its text; "
            f"page {page} must carry the canary above."
        ))
        if page < pages:
            body.append(PAGE_BREAK)
    body.append(
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" '
        'w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>'
    )
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        "<w:body>" + "".join(body) + "</w:body></w:document>\n"
    )


def write_docx(path: Path, pages: int) -> bytes:
    buffer = path.parent / (path.name + ".tmp")
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, payload in (
            ("[Content_Types].xml", CONTENT_TYPES),
            ("_rels/.rels", RELS),
            ("word/document.xml", document(pages)),
        ):
            info = zipfile.ZipInfo(name, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, payload)
    data = buffer.read_bytes()
    buffer.replace(path)
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", default=str(Path(__file__).parent))
    parser.add_argument("--check", action="store_true",
                        help="compare against the committed files instead of writing")
    args = parser.parse_args()
    target = Path(args.directory)
    if not target.is_dir():
        print(f"FAIL  {target} is not a directory", file=sys.stderr)
        return 2

    failures = 0
    for name, pages in (("office-1p.docx", 1), ("office-50p.docx", 50)):
        path = target / name
        expected = document(pages).encode("utf-8")
        if args.check:
            if not path.exists():
                print(f"FAIL  {path} is missing")
                failures += 1
                continue
            with zipfile.ZipFile(path) as archive:
                actual = archive.read("word/document.xml")
            if actual != expected:
                print(f"FAIL  {path}: word/document.xml differs from the generator")
                failures += 1
                continue
            print(f"PASS  {path} matches the generator ({pages} page(s))")
        else:
            data = write_docx(path, pages)
            print(f"wrote {path} ({pages} page(s), {len(data)} bytes)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
