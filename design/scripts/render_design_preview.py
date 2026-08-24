#!/usr/bin/env python3
"""Render the connected design canvas as a static, offline-viewable HTML page.

`Screen Recorder - Desktop MVP.dc.html` is a Claude Design canvas document: its
markup lives inside <x-dc>, and `support.js` boots it with React loaded from a
CDN. That makes the file unviewable without network access, so this script
extracts the same markup into a plain page that renders from the local design
system alone.

The .dc.html remains the visual source of truth. Re-run this after pulling a new
design revision:

    python3 scripts/render_design_preview.py
"""

from __future__ import annotations

import re
from pathlib import Path

DESIGN_DIR = Path(__file__).resolve().parent.parent
SOURCE = DESIGN_DIR / "Screen Recorder - Desktop MVP.dc.html"
OUTPUT = DESIGN_DIR / "preview.html"

# The document declares one editable prop (data-props on its <script type="text/x-dc">).
# Its renderVals() is reproduced here so the static page shows the same default frame.
UPLOAD_PERCENT_DEFAULT = 62
TOTAL_MB = 1.02 * 1024


def upload_values(percent: int) -> dict[str, str]:
    percent = max(0, min(100, percent))
    sent = round(TOTAL_MB * percent / 100)
    return {
        "pctLabel": f"{percent}%",
        "pctWidth": f"{percent}%",
        "sentLabel": f"{sent / 1024:.2f} GB" if sent >= 1024 else f"{sent} MB",
    }


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")

    xdc = re.search(r"<x-dc(?:\s[^>]*)?>(.*)</x-dc>", source, re.S).group(1)
    helmet_tag = re.search(r"<helmet[^>]*>.*?</helmet>", xdc, re.S).group(0)
    helmet = re.search(r"<helmet[^>]*>(.*?)</helmet>", xdc, re.S).group(1)
    body = xdc.replace(helmet_tag, "")

    values = upload_values(UPLOAD_PERCENT_DEFAULT)
    body = re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda m: values[m.group(1)], body)

    # Canvas-only directive; meaningless outside the design host.
    helmet = re.sub(r'<meta name="design_doc_mode"[^>]*>\s*', "", helmet)

    OUTPUT.write_text(
        f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Screen Recorder — Desktop MVP (static design reference)</title>
<!-- GENERATED from "Screen Recorder - Desktop MVP.dc.html" by scripts/render_design_preview.py.
     Do not edit: re-run the script after pulling a new design revision.
     The .dc.html is the source of truth; this file only makes it viewable offline,
     because the canvas runtime (support.js) loads React from a CDN. -->
{helmet.strip()}
</head>
<body>
{body.strip()}
</body>
</html>
""",
        encoding="utf-8",
    )
    print(f"wrote {OUTPUT.relative_to(DESIGN_DIR)}")


if __name__ == "__main__":
    main()
