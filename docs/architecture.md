# Architecture

Native macOS app: SwiftUI shell over AppKit/TextKit 1 editors. No web-based
editing — the only WKWebView is the read-mostly Preview.

## Document model

The source of truth for a document is the **markdown string** inside
`MarkdownDocument` (`EditMD/EditMD/Document/`). Everything else — attributed
text in Visual, HTML in Preview, highlight spans in Source — is a projection
of that string and must serialize back to it losslessly.

`DocumentRegistry` owns one model per URL. Open editors acquire/release the
model by identity; autosave, external-change detection, and agent edits all go
through the registry:

- Agent edits and accepted review suggestions are applied only via
  `DocumentRegistry.applyAgentEdit`. Writing the file any other way makes the
  file watcher treat the change as external.
- The registry's own flush updates `knownModDate` and re-arms the watch, so a
  self-write is never reported back as an external change.
- `ReferenceFileDocument` callbacks are nonisolated and `FileWrapper` is not
  `Sendable`; the snapshot type stays `@unchecked Sendable` deliberately.

## Windows

The main window swaps files inside a workspace. Additional lite windows open
through `WindowGroup(for: URL)` and attach to the same registry models, so two
windows on one file share text and undo. Standard Cut/Copy/Paste/Undo travel
the responder chain; editor-specific actions are routed through SwiftUI
focused values (`EditMD/EditMD/Views/FocusedValues.swift`).

## Three modes, three code paths

A markdown feature that spans modes has **three independent implementations**
plus the round-trip, and a change must be checked in all of them:

| Mode | Render path | Files |
| --- | --- | --- |
| Source | `collectSpans` highlight + lint | `SourceTextView.swift`, `MarkdownHighlighter.swift`, `MarkdownLint.swift` |
| Visual | `VisualRenderer` → attributed string | `MarkdownToAttributed.swift`, `Visual*.swift` |
| Preview | `HTMLBodyVisitor` → HTML in WKWebView | `MarkdownHTML.swift`, `MarkdownPreviewView.swift` |

Serialization back from Visual lives in `AttributedToMarkdown.swift` and runs
synchronously on every keystroke — Visual editing is only correct if
render → serialize is a fixed point.

Key round-trip contracts:

- **Islands** (`.raw` attribute) carry the verbatim markdown of constructs the
  attributed view displays differently (island tables, complex blocks). The
  serializer reads the `.raw` payload, never the display text. Native tables
  are rebuilt through `TableGrid`; island tables through `replaceTableIsland`.
- **Frontmatter** is invisible in Visual and Preview — the right-inspector
  "Properties" panel owns it. The Visual render skips the block and the
  coordinator re-prepends it verbatim via `composeDocumentWithFrontmatter`;
  the block must survive byte-exact.
- **Formulas** are parsed over masked text preserving UTF-16 offsets; Visual
  keeps the original TeX in the `.mdMathTex` attribute (SwiftMath renders it,
  Preview uses bundled KaTeX).
- Rendered insertions into Visual go through `renderForInsertion`, which
  remaps group ids so pasted content cannot collide with existing islands.
- All offsets everywhere are **UTF-16** (NSString space).

## Paste

Special paste is an ordered lazy funnel — Source: table → image → plain text;
Visual: markdown/table → image → plain text. Image detection must not consume
the TIFF/PDF preview flavors that Word/Excel/Numbers put on the pasteboard
alongside text. One contextual guard serves the paste path and the toolbar
button: Source never inserts structure inside a fence; Visual never inserts it
into `codeBlock`, `tableCell`, or `.raw`. A failed image save returns `false`
so the ordinary paste still delivers the text flavor. Paste stays synchronous
(honest plain-text fallback), so its file scanning must be minimal.

`markdownImageSyntax` is the single serializer of image markdown and
`supportedImageMIMETypes` the single source of image extensions/UTTypes.
Assets are deduplicated by content — size check first, then bytes.

## Performance rules

- Disk I/O, `Process` runs, and full diffs never execute on the main actor and
  are never computed from a SwiftUI `body`. Folder stats, git status, review
  anchors, and highlighting use cache + background refresh
  (stale-while-revalidate).
- Highlight.js never blocks a keystroke; blocking use is acceptable only for
  one-off HTML/PDF export.
- Heavy payloads must not be hashed inside NSTextStorage attribute values —
  `MDBlock.hash(into:)` is O(1) by contract.
- `maxNativeTableCells` (layout survival) and `markdownIsHeavy` (feature
  degradation) answer different questions and must stay independent.
- Line numbers are drawn in the left text inset, not an `NSRulerView`; strip
  and gutter geometry comes from `EditorFieldGeometry` only.
- Overlay views are pooled; adding/removing subviews inside layout creates a
  layout cycle. `NSTextView.isFlipped == true`.
- Appearance is resolved at draw time with dynamic `NSColor`s — never bake
  `NSApp.effectiveAppearance` into window content.
- For AppKit delegate methods that Swift 6 does not annotate `@MainActor`, use
  `nonisolated` + `MainActor.assumeIsolated` only where AppKit guarantees the
  main thread.

## Localization

Development language is English: user-facing strings are English literals
(SwiftUI keys or `String(localized:)`), translated to Russian in
`Resources/Localizable.xcstrings`. Protocol messages and logs are not
localized — agents read them. Settings ▸ General ▸ Language writes
`AppleLanguages` (see `Views/AppLanguage.swift`); the test host forces English
with the scheme argument `-AppleLanguages (en)`.
