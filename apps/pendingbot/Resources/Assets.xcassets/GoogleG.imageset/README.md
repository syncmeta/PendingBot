# GoogleG asset

Google's full-colour "G", 20×20.43pt, transparent background, one SVG with
`preserves-vector-representation`. Shared by `WelcomeView` (iOS) and
`MacWelcomeView` (Mac).

## Provenance

Prepared by `scripts/trim-google-g-svg.py` from the file the author supplied out
of Google's own brand pack:

| | |
|---|---|
| file | `GoogleG_FullColor_RGB_alpha.svg` — Illustrator 30.0 export, 1024×1024 artboard |
| sha256 | `eb6f54ece379580a587d22bafd07b62ac526538a3fbe18b4c7cecd1b4f5bddd0` |

**The only edit is the root `<svg>` element** — `width` / `height` / `viewBox`,
i.e. crop the canvas to the mark and declare a 20pt natural size. Nothing inside
the document is touched: not the clip path, not the artwork, not one colour.
Without the crop, Xcode would treat the asset as 1024pt and rasterise its
fallback bitmap at 3072px.

```
python3 scripts/trim-google-g-svg.py <GoogleG_FullColor_RGB_alpha.svg> \
  apps/pendingbot/Resources/Assets.xcassets/GoogleG.imageset/g-logo.svg
```

## What this SVG actually is, and why it still wins

It is not a pure-vector drawing. Illustrator exported the mark as **one vector
clip path (the G outline) filled by an embedded 1049×1076 RGBA bitmap** carrying
the gradient. So the *silhouette* is resolution-independent; the *colour* is not.

That is still the best option available, measured against the two alternatives:

| route | colour fidelity | on-screen at 19pt | in `Assets.car` |
|---|---|---|---|
| **this SVG** | exact (ΔRGB ≈ 2 vs the master, pure resampling noise) | crispest | 147 KB vector + 4 KB fallback |
| PNG slices from `GoogleG_FullColor_RGB.png` | exact | visibly softer — the mark is only 920×940 in that master, so 60px is a double downsample | 8 KB |
| EPS → PDF via ghostscript | **wrong** — Google blue `#3186FF` renders `#4B79C6`, mean ΔRGB ≈ 15 | dull, dithered | 940 KB |

The PDF route was rejected on colour: recolouring the mark is exactly what the
guidelines forbid, and `-dColorConversionStrategy` at `/RGB` and at
`/LeaveColorUnchanged` both failed to recover it. Between the remaining two, the
SVG renders visibly better at 19pt for 139 KB more — the outline is rasterised
straight to the target size instead of being resampled twice.

## Google's own distributed SVGs do not work outside a browser — checked, closed

`signin-assets.zip` does ship 24 SVGs. They are unusable here, and this is not a
matter of taste: the G's gradient is a CSS `conic-gradient` inside a
`<foreignObject>` (plus seven `feGaussianBlur` filters), with **no plain-SVG
fallback** — zero `<linearGradient>`, `<radialGradient>` or `<stop>` elements in
the file. `foreignObject` content is HTML, so any renderer that is not a browser
drops it. Rendered with `rsvg-convert`, Google's own dark icon comes out as a
few red and blue smears on black, off by mean ΔRGB ≈ 50 inside the G box.

So: **there is no Google-distributed true-vector G.** Don't go looking again.

## One asset, not a light/dark pair

The asset catalog can carry `appearances` variants, and it's tempting to ship
two. Don't: Google's light and dark buttons draw the **identical** G — same path,
same gradient — and only the fill underneath changes. A dark-mode variant would
by definition be a *modified* Google logo, which the guidelines forbid. The
theming belongs to the button, not the mark.

The mark's counter (the enclosed space inside the G) is transparent, so on the
dark button it shows the dark fill through. That is not a hole to be patched —
it is exactly how Google's own dark button renders, verified pixel-for-pixel
against their `Theme=Dark, Show text=No` artwork (max delta 1.08/255).

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
