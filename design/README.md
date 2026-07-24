# App icon

Source and generator for the macOS app icon.

- `AppIcon.svg` — the `.md` glyph: a black wordmark on a transparent square
  (128×128 viewBox). This is the only hand-authored asset; everything else is
  derived.
- `make-appicon.swift` — composes the glyph onto the standard macOS Big Sur
  plate (a light rounded square with a contact shadow), slices a full
  `.iconset`, and packs it into `../EditMD/EditMD/Resources/AppIcon.icns` with
  `iconutil`. No external dependencies — `NSImage` rasterizes the SVG and
  CoreGraphics draws the plate.

## Regenerate

```bash
swift design/make-appicon.swift
```

Writes the intermediate `.iconset` to `design/build/` (git-ignored) and
overwrites the tracked `.icns`. The app references it via
`INFOPLIST_KEY_CFBundleIconFile: AppIcon` in `EditMD/project.yml`.

To retune the look — plate colours, glyph colour, glyph size, shadow — edit
the `Style` block at the top of `make-appicon.swift` and rerun. To change the
mark itself, replace `AppIcon.svg` (keep it a black shape on transparent, its
tight bounding box is auto-detected and centred).
