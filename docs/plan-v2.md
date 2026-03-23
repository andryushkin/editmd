# EditMD v2 — Plan

## Status

| Feature | Status |
|---|---|
| Live Preview / cursor proximity | ✅ Done |
| Font size settings via UserDefaults | ✅ Done |
| Word/character counter in status bar | ⬜ Todo |
| Formatting hotkeys (Cmd+B, Cmd+I) | ⬜ Todo |
| .textbundle support (images) | ⬜ Todo |

## Details

### ✅ Live Preview / cursor proximity
Markdown markers (`#`, `**`, `*`, `>`, links) hidden when cursor is not on that line.
Implemented via `NSTextLayoutManagerDelegate` + `rehighlight` + `activeLine` tracking.

### ✅ Font size settings
`EditorFontSettings` singleton backed by UserDefaults. Format menu: Bigger (⌘=) / Smaller (⌘−).

### ⬜ Word/character counter
Show word and character count in the window status bar.

### ⬜ Formatting hotkeys
Cmd+B → wrap selection in `**...**`
Cmd+I → wrap selection in `*...*`

### ⬜ .textbundle support
Support for `.textbundle` format to allow embedding local images in documents.
