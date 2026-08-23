#!/usr/bin/env python3
"""Slice Google's official full-colour "G" master into the @1x/@2x/@3x PNGs
that `GoogleG.imageset` ships.

Source
------
`GoogleG_FullColor_RGB.png` out of Google's brand pack (2820x2820, RGBA with a
real alpha channel). The mark itself occupies a 920x940 box in the middle of
that canvas; everything around it is transparent clear space. We trim the empty
canvas — no pixel of the mark is touched, recoloured, or cropped — and place the
mark in a square box scaled to Google's own geometry: their 44pt sign-in button
draws a 20pt-tall G, so 1x is 20px, 2x is 40px, 3x is 60px.

The mark is 920/940 = 0.979 as wide as it is tall, so a square box leaves a
~0.2pt transparent sliver either side at 1x. That is deliberate: it keeps every
slice square and matches the 20x20pt box Google uses in their own artwork.

Usage
-----
    python3 scripts/slice-google-g-logo.py <GoogleG_FullColor_RGB.png> <out-dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

BASE_PT = 20          # Google draws a 20pt G inside their 44pt button.
SCALES = (1, 2, 3)
EXPECTED_MASTER = (2820, 2820)


def trim_to_mark(master: Image.Image) -> Image.Image:
    alpha = np.asarray(master)[..., 3]
    ys, xs = np.nonzero(alpha > 0)
    if not len(xs):
        raise SystemExit("master is fully transparent — wrong file?")
    return master.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} <GoogleG_FullColor_RGB.png> <out-dir>")
    src, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    master = Image.open(src).convert("RGBA")
    if master.size != EXPECTED_MASTER:
        print(f"  note: master is {master.size}, expected {EXPECTED_MASTER} — continuing")
    mark = trim_to_mark(master)
    print(f"  mark occupies {mark.width}x{mark.height} of {master.width}x{master.height}")

    for scale in SCALES:
        side = BASE_PT * scale
        # Fit by height (Google's dimension), centre the ~2% narrower width.
        height = side
        width = max(1, round(mark.width * height / mark.height))
        resized = mark.resize((width, height), Image.LANCZOS)
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        canvas.paste(resized, ((side - width) // 2, 0))
        name = f"g-logo{'' if scale == 1 else f'@{scale}x'}.png"
        canvas.save(out_dir / name, optimize=True)
        print(f"  wrote {name}  {side}x{side}  (mark {width}x{height})")


if __name__ == "__main__":
    main()
