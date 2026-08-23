# GoogleG asset

Google's full-colour "G" — 20×20pt, transparent background, @1x/@2x/@3x.
Shared by `WelcomeView` (iOS) and `MacWelcomeView` (Mac).

## Provenance

Sliced by `scripts/slice-google-g-logo.py` from the master the author supplied
out of Google's own brand pack:

| | |
|---|---|
| file | `GoogleG_FullColor_RGB.png` — 2820×2820, RGBA, real alpha |
| sha256 | `4d5cfbd85af19c003770a74f8de210156ca42c54ac0a4cb0d95572c286c882a6` |
| sibling | `GoogleG_FullColor_RGB.eps` — Illustrator 30.0, 12/10/25, bbox 1024×1024, sha256 `86ed2344ec60582f709e49884ba0b41b994a53fdf425445d293a83dd595f8c0b` |

The mark occupies a 920×940 box in the middle of that 2820px canvas; the rest is
transparent clear space. The script trims the empty canvas and scales the mark to
Google's own geometry — their 44pt sign-in button draws a 20pt-tall G — then
centres it in a square box. **No pixel of the mark is recoloured, cropped, or
redrawn.** The masters are not in the repo (3.6 MB of binary); they live in the
author's brand pack, and the hashes above identify exactly which files these came
from.

```
python3 scripts/slice-google-g-logo.py <GoogleG_FullColor_RGB.png> \
  apps/pendingbot/Resources/Assets.xcassets/GoogleG.imageset/
```

## Why raster and not vector — this was tried and rejected on evidence

Vector would have been nicer: one file, every scale, no ladder to keep in sync.
The EPS converts to a genuine vector PDF (shading dictionaries, no embedded
raster), and Xcode accepts it with `preserves-vector-representation`. It shipped
and rendered. It was still wrong, for two independent reasons:

1. **The colours came out wrong.** Ghostscript's EPS→PDF step shifts the
   gradient: Google blue `#3186FF` renders as roughly `#4B79C6`, green `#0EBC5E`
   as `#21B04A`, mean ΔRGB ≈ 15/255 across the mark. `-dColorConversionStrategy`
   set to `/RGB` and to `/LeaveColorUnchanged` were both tried and neither
   recovers it. In the simulator it reads visibly duller and slightly dithered
   next to the raster. Recolouring the mark is exactly what the branding
   guidelines forbid, so a lossy colour path disqualifies itself.
2. **940 KB.** That is what Xcode stored as the vector representation in
   `Assets.car`, for a mark that is never drawn above 20pt. The three PNGs are
   8 KB in total.

These slices land within ΔRGB ≈ 2–5 of Google's own @1x/@2x/@3x button renders
(vs ≈ 15 for the vector route), i.e. inside small-raster resampling noise.

If Google's brand pack ever yields a **PDF or SVG straight from Google** — not
one we converted — vector becomes worth revisiting; the objection is to our
conversion, not to vector.

## One asset, not a light/dark pair

The asset catalog can carry `appearances` variants, and it's tempting to ship
two. Don't: Google's light and dark buttons draw the **identical** G — same path,
same gradient — and only the fill underneath changes. A dark-mode variant would
by definition be a *modified* Google logo, which the guidelines forbid. The
theming belongs to the button, not the mark.

The mark's counter (the enclosed space inside the G) is transparent, so on the
dark button it shows the dark fill through. That is not a hole to be patched —
it is exactly how Google's own dark button renders, verified pixel-for-pixel
against their `Theme=Dark, Show text=No` artwork.

## Rules that constrain this asset

- Standard full-colour G only. Never recolour, add a stroke, tint it as a
  template, or drop it into a `Circle().fill()`.
- It must sit on one of the three approved fills — see `Theme.Palette.googlePill`
  / `googlePillStroke`, which carry the guideline's exact hexes.
- Keep at least the guideline's clear space around it (Google's own 44pt button
  gives a 20pt G 12pt of padding on every side).
- <https://developers.google.com/identity/branding-guidelines>

## History

Until 2026-08-23 this imageset held a single 80×80 `g-logo.png` in **RGB with no
alpha channel** — the white button fill was baked into the pixels, so dark mode
showed a white square around the G (human todo #8) — and only the 1x slot was
filled, so retina screens upscaled it. Both are fixed here.
