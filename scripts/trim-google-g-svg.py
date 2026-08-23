#!/usr/bin/env python3
"""Prepare Google's official "G" SVG for the asset catalog.

The only edit is to the root <svg> element: crop the canvas down to the mark and
declare a natural size. Nothing inside the document is touched — not the clip
path, not the embedded artwork, not a single colour.

Why crop: Illustrator exports the mark on a 1024x1024 artboard with the mark
itself occupying x 52..972, y 42..982. Left as-is, Xcode would treat the asset
as 1024pt and rasterise its fallback bitmap at 3072px. Windowing the viewBox to
the mark makes the asset 20pt — matching the 20pt G in Google's own 44pt sign-in
button — and lets the 19pt frame in `WelcomeView` fill correctly.

Usage:
    python3 scripts/trim-google-g-svg.py <GoogleG_FullColor_RGB_alpha.svg> <out.svg>
"""
from __future__ import annotations

import sys
from pathlib import Path

# Bounding box of the mark inside the 1024pt artboard, measured by rendering the
# source at 4x and reading back the alpha channel.
BOX = (52, 42, 920, 940)          # x, y, width, height
NATURAL_PT = 20                   # Google draws a 20pt G in their 44pt button.

SOURCE_ROOT = '<svg id="art_layer" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" viewBox="0 0 1024 1024">'


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} <source.svg> <out.svg>")
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    svg = src.read_text(encoding="utf-8")
    if svg.count(SOURCE_ROOT) != 1:
        raise SystemExit(
            "root <svg> element does not match the expected Illustrator export — "
            "re-measure the mark's bounding box before trusting BOX above."
        )
    x, y, w, h = BOX
    height_pt = round(NATURAL_PT * h / w, 4)
    root = (
        '<svg id="art_layer" xmlns="http://www.w3.org/2000/svg" '
        'xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" '
        f'width="{NATURAL_PT}" height="{height_pt}" viewBox="{x} {y} {w} {h}">'
    )
    dst.write_text(svg.replace(SOURCE_ROOT, root), encoding="utf-8")
    print(f"  wrote {dst}  natural size {NATURAL_PT}x{height_pt}pt, viewBox {x} {y} {w} {h}")


if __name__ == "__main__":
    main()
