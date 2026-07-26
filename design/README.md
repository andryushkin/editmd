# Design assets

Sources and generators for the app icon and the repository's social preview.

- `AppIcon.svg` — the `.md` glyph: a black wordmark on a transparent square
  (128×128 viewBox). This is the only hand-authored asset; everything else is
  derived.
- `make-appicon.swift` — composes the glyph onto the standard macOS Big Sur
  plate (a light rounded square with a contact shadow), slices a full
  `.iconset`, and packs it into `../EditMD/EditMD/Resources/AppIcon.icns` with
  `iconutil`. No external dependencies — `NSImage` rasterizes the SVG and
  CoreGraphics draws the plate.
- `make-social.swift` / `social-preview.png` — the card GitHub serves as
  `og:image`. The generator reads the tracked `.icns` rather than redrawing the
  mark, so the card cannot drift from the app icon.

## Regenerate the icon

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

## Regenerate the social preview

```bash
swift design/make-social.swift
```

Overwrites the tracked `design/social-preview.png` (1280×640, GitHub's
recommended size; the limit is 1 MB). Wording, colours and layout live in the
`Style` block at the top of the script. Regenerate the icon first if it
changed — the card is composed from the `.icns`.

**Uploading is manual.** GitHub exposes no API for the social preview, so the
PNG goes in through Settings ▸ General ▸ Social preview ▸ Edit. The tracked
file is the source of truth for the next upload; the bottom band of the card is
deliberately empty because some clients crop the lower edge.
