# GitHubMark asset

This imageset is intentionally empty in source control. The official "Octocat / GitHub mark" lives at GitHub's brand toolkit and isn't fetched by an automated script.

## How to populate

1. Grab the mark from https://github.com/logos (white version, "GitHub mark / Octocat" – the silhouette, not the wordmark).
2. Drop the file(s) into this directory and update `Contents.json`:
   - Single SVG/PDF (preserve vector): add `"filename": "github-mark.pdf"` to the universal entry, and add `"properties": { "preserves-vector-representation": true }`.
   - Or three PNGs: name them `github-mark.png`, `github-mark@2x.png`, `github-mark@3x.png` and reference them in the three scale entries.
3. Use the **white** mark — `WelcomeView` renders it template-style on a near-black pill, so it should be solid white-on-transparent.

## Brand constraints

- GitHub's logo guidelines: <https://github.com/logos>. Don't recolor or distort.
- The button background uses near-black (#0D1117 — GitHub's canvas color) instead of pure black, so it's visually distinct from the Apple pill.

Until this asset is provided, `WelcomeView` falls back to the SF Symbol `chevron.left.forwardslash.chevron.right` so the button is still visible during dev.
