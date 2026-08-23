#!/usr/bin/env python3
"""Derive a transparent-background Google "G" asset from Google's official
Sign-in assets, without ever repainting the logo by hand.

Why this exists
---------------
Google ships the "Sign in with Google" artwork as *finished buttons* — the
G is already composited onto one of the three approved fills (Light #FFFFFF,
Dark #131314, Neutral #F2F2F2). There is no bare transparent G in the pack.
Keying the white out of a single render would leave an anti-aliasing fringe
and would count as modifying someone else's trademark.

Instead we solve for the matte exactly. Every pixel of the icon-only button is

    C = F + (1 - a) * B        # F = premultiplied logo, B = known button fill

Two renders of the *same* logo over two *different* known fills give two
equations per channel, so `a` and `F` fall out with no guessing:

    C_light - C_dark = (1 - a) * (B_light - B_dark)

The Neutral render is deliberately held out of the solve and used as an
independent check: re-compositing our result onto #F2F2F2 must reproduce
Google's own Neutral button. It does, to within 8-bit rounding (<2/255).

Usage
-----
    curl -sSLO https://developers.google.com/static/identity/images/signin-assets.zip
    unzip -q signin-assets.zip -d assets
    python3 scripts/extract-google-g-logo.py assets <output-dir>

Writes g-logo.png / g-logo@2x.png / g-logo@3x.png (20/40/60 px), matching the
20pt G that Google's own 44pt iOS button uses.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

# The three approved button fills, straight from the branding guidelines.
FILLS = {
    "Light": (0xFF, 0xFF, 0xFF),
    "Dark": (0x13, 0x13, 0x14),
    "Neutral": (0xF2, 0xF2, 0xF2),
}

# Icon-only ("Show text=No") square buttons. NB: Google mis-files the @1x Light
# artwork under the Neutral folder — the filename, not the folder, is truthful.
SOURCES = {
    1: {
        "Light": "iOS/PNG @1x/Neutral/Theme=Light, Show text=No, Shape=Square, Platform=iOS.png",
        "Dark": "iOS/PNG @1x/Dark/Theme=Dark, Show text=No, Shape=Square, Platform=iOS.png",
        "Neutral": "iOS/PNG @1x/Neutral/Theme=Neutral, Show text=No, Shape=Square, Platform=iOS.png",
    },
    2: {
        "Light": "iOS/PNG @2x/Light/Theme=Light, Show text=No, Shape=Square, Platform=iOS@2x.png",
        "Dark": "iOS/PNG @2x/Dark/Theme=Dark, Show text=No, Shape=Square, Platform=iOS@2x.png",
        "Neutral": "iOS/PNG @2x/Neutral/Theme=Neutral, Show text=No, Shape=Square, Platform=iOS@2x.png",
    },
    3: {
        "Light": "iOS/PNG @3x/Light/Theme=Light, Show text=No, Shape=Square, Platform=iOS@3x.png",
        "Dark": "iOS/PNG @3x/Dark/Theme=Dark, Show text=No, Shape=Square, Platform=iOS@3x.png",
        "Neutral": "iOS/PNG @3x/Neutral/Theme=Neutral, Show text=No, Shape=Square, Platform=iOS@3x.png",
    },
}

# The G occupies pt 12..32 of the 44pt icon button (12pt clear space all round).
INSET, EXTENT, BUTTON = 12, 20, 44
TOLERANCE = 2.0  # 8-bit rounding; anything above this means the solve is wrong.


def extract(assets: Path, scale: int) -> Image.Image:
    src = SOURCES[scale]
    lo, hi = INSET * scale, (INSET + EXTENT) * scale

    planes = {}
    for theme, rel in src.items():
        img = np.asarray(Image.open(assets / rel).convert("RGBA"), dtype=float)
        side = BUTTON * scale
        if img.shape[:2] != (side, side):
            raise SystemExit(f"@{scale}x {theme}: expected {side}px square, got {img.shape[:2]}")
        if img[lo:hi, lo:hi, 3].min() != 255:
            raise SystemExit(f"@{scale}x {theme}: logo box is not fully opaque — wrong crop?")
        planes[theme] = img[lo:hi, lo:hi, :3]

    b_light, b_dark = np.array(FILLS["Light"], float), np.array(FILLS["Dark"], float)
    delta_bg = b_light - b_dark

    # Least squares across the three channels of the Light/Dark pair.
    transparency = ((planes["Light"] - planes["Dark"]) * delta_bg).sum(axis=2) / (delta_bg**2).sum()
    transparency = np.clip(transparency, 0.0, 1.0)
    alpha = 1.0 - transparency

    from_light = planes["Light"] - transparency[..., None] * b_light
    from_dark = planes["Dark"] - transparency[..., None] * b_dark
    premultiplied = (from_light + from_dark) / 2.0

    with np.errstate(invalid="ignore", divide="ignore"):
        rgb = np.where(alpha[..., None] > 1e-6, premultiplied / np.maximum(alpha[..., None], 1e-6), 0.0)

    out = np.zeros(rgb.shape[:2] + (4,), np.uint8)
    out[..., :3] = np.rint(np.clip(rgb, 0, 255)).astype(np.uint8)
    out[..., 3] = np.rint(alpha * 255).astype(np.uint8)
    logo = Image.fromarray(out)

    # Verify against every official render, Neutral included (never used above).
    quantised = np.asarray(logo, float)
    a8 = quantised[..., 3:4] / 255.0
    for theme, plane in planes.items():
        recomposed = quantised[..., :3] * a8 + np.array(FILLS[theme], float) * (1 - a8)
        worst = np.abs(recomposed - plane).max()
        if worst > TOLERANCE:
            raise SystemExit(f"@{scale}x {theme}: round-trip off by {worst:.2f} (> {TOLERANCE})")
        print(f"  @{scale}x {theme:<8} round-trip max delta {worst:.2f}/255")
    return logo


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} <unzipped-signin-assets-dir> <output-dir>")
    assets, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    for scale in (1, 2, 3):
        suffix = "" if scale == 1 else f"@{scale}x"
        extract(assets, scale).save(out_dir / f"g-logo{suffix}.png", optimize=True)
        print(f"  wrote g-logo{suffix}.png")


if __name__ == "__main__":
    main()
