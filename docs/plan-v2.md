# EditMD v2 — Plan

## Status

| Feature | Status |
|---|---|
| Live Preview / cursor proximity | ✅ Done |
| Font size settings via UserDefaults | ✅ Done |
| Word/character counter in status bar | ✅ Done |
| Formatting hotkeys (Cmd+B, Cmd+I) | ✅ Done |
| .textbundle support (images) | ✅ Done |

## Details

### ✅ Live Preview / cursor proximity
Markdown markers (`#`, `**`, `*`, `>`, links) hidden when cursor is not on that line.
Implemented via `NSTextLayoutManagerDelegate` + `rehighlight` + `activeLine` tracking.

### ✅ Font size settings
`EditorFontSettings` singleton backed by UserDefaults. Format menu: Bigger (⌘=) / Smaller (⌘−).

### ✅ Word/character counter
Status label at the bottom of the editor showing "N words  M chars".
Updates on every keystroke via `textDidChange`. Implemented in `MarkdownEditorView.swift`.

### ✅ Formatting hotkeys
Cmd+B → wrap selection in `**...**`
Cmd+I → wrap selection in `*...*`
Implemented via `toggleBold`/`toggleItalic` in `MarkdownEditorView.swift`, menu items in `AppDelegate.swift`.
