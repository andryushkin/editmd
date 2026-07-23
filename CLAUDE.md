# EditMD — working guide

A short development handbook. The detailed decision log and investigation
history (`HISTORY.md`) moved out of the repository on 2026-07-23 and lives in
the author's vault; the future of in-repo docs is being redesigned. Do not
re-add release chronology or one-off investigation details here.

## What this is

A native Markdown editor for macOS built on SwiftUI + AppKit/TextKit 1. The
main window swaps files within a workspace; lite windows open via
`WindowGroup(for: URL)`. `DocumentRegistry` owns the models, autosave, and
external changes; the source of truth is the markdown string in
`MarkdownDocument`.

Three modes:

- **Source** — raw markdown with highlighting and lint: `SourceTextView.swift`,
  `MarkdownHighlighter.swift`, `MarkdownLint.swift`.
- **Visual** — attributed WYSIWYG with synchronous serialization:
  `MarkdownToAttributed.swift`, `AttributedToMarkdown.swift`, `Visual*.swift`.
- **Preview** — mostly read-only HTML in a WKWebView; task/status tokens are
  interactive: `MarkdownHTML.swift`, `MarkdownPreviewView.swift`.

Sidebar: Files / Outline / Git / Review / Tags. The Source/Visual split with
live Preview toggles with ⌥⌘P. PDFs and local images open read-only; images can
be added with a button or pasted from the clipboard.

## Project map

- `EditMD/EditMD/App/` — lifecycle, windows, File/Format/View commands, open
  routing.
- `EditMD/EditMD/Document/` — `MarkdownDocument`, `DocumentStore`,
  `DocumentRegistry`.
- `EditMD/EditMD/Editor/` — Source/Visual, round-trip, tables, formulas,
  highlighting, lint, review, diff, PDF export.
- `EditMD/EditMD/Views/` — layout, Preview, sidebars, settings, PDF/image
  viewer (`PDFViewerView.swift`).
- `EditMD/EditMD/Integration/` — Claude IDE WebSocket/MCP, diff approval,
  control socket, skill installer.
- `EditMD/EditMDTests/` — unit/integration tests.
- `EditMD/project.yml` — the single source of the Xcode project structure;
  after changing targets/resources run xcodegen.

Dependencies: `swift-markdown`, `SwiftMath`, `HighlighterSwift`. KaTeX is
bundled offline in `Resources/katex/`.

## Build and test

From the repository root:

```bash
xcodegen generate --spec EditMD/project.yml
xcodebuild -project EditMD/EditMD.xcodeproj -scheme EditMD -destination 'platform=macOS' build
xcodebuild -project EditMD/EditMD.xcodeproj -scheme EditMD -destination 'platform=macOS' test
```

The scheme already disables code coverage. Verify real errors through
`xcodebuild`, not through the diagnostics of a single open Swift file. After
changes run the targeted tests, then the full suite and `git diff --check`.

## Key invariants

### Document and windows

- One model per URL lives in `DocumentRegistry`; open editors acquire/release
  it by identity.
- Agent edits and review suggestions are applied only through
  `DocumentRegistry.applyAgentEdit`, otherwise the file watcher treats them as
  an external change.
- Our own flush updates `knownModDate` and re-arms the watch.
- `ReferenceFileDocument` callbacks are nonisolated; `FileWrapper` is not
  `Sendable`, so the snapshot stays `@unchecked Sendable`.
- Standard Cut/Copy/Paste/Undo go through the responder chain; actions of a
  specific editor go through focused values.

### Source / Visual / Preview

- A cross-cutting markdown feature has three independent paths:
  Source=`collectSpans`, Visual=`VisualRenderer`, Preview=`HTMLBodyVisitor`.
  Check all three plus the round-trip.
- EditMD plugins are built-in Swift types from `BuiltInPluginRegistry` only,
  activated per document via frontmatter. Do not add loading of JavaScript,
  external bundles, or downloaded executable code; a semantic token must
  preserve UTF-16 offsets and pass Source/Visual/Preview + round-trip.
- The add-plugin menu lives in the right inspector's "Properties" panel
  (registry-driven). Installation must be undoable, must not duplicate an
  already-declared block, and must merge correctly into existing frontmatter.
- `.raw` is the verbatim source of truth for islands. Table display text may
  differ; the serializer reads the `.raw` payload.
- Frontmatter is rendered neither in Visual nor in Preview — the "Properties"
  panel owns it. The Visual render skips the block, and the coordinator
  prepends the verbatim block during serialization via
  `composeDocumentWithFrontmatter`; byte-exactness of the block is mandatory.
- Formulas are parsed over masked text preserving UTF-16 offsets; Visual keeps
  the original TeX in `.mdMathTex`.
- Rendered Visual insertions go only through `renderForInsertion`, which remaps
  group ids. Native tables are rebuilt through `TableGrid`, island tables
  through `replaceTableIsland`.
- Heavy payloads must not be hashed inside NSTextStorage attribute values.
  `MDBlock.hash(into:)` must be O(1).
- `maxNativeTableCells` and `markdownIsHeavy` solve different problems and must
  not be coupled.
- Source aligns tables display-only via `.kern`; do not change the markdown
  bytes and strip `.kern` from typing attributes.
- `textView.string = …` and `setAttributedString` synchronously invoke the
  selection delegate: read the caret position before replacing.
- Source presentation attributes that change layout must be storage
  attributes; the review wash uses temporary layout-manager attributes.

### Paste and images

- Special paste is an ordered lazy funnel. **Source:** table → image → plain
  text. **Visual:** markdown/table → image → plain text. Image detection must
  not eat the TIFF/PDF preview from Word/Excel/Numbers first.
- One contextual guard serves both paste and the button. Source does not
  insert structure inside a fence; Visual does not insert it into `codeBlock`,
  `tableCell`, or `.raw`.
- An image-save failure returns `false` so the ordinary paste gets the text
  part of the clipboard. Do not mark a payload as handled if the insertion did
  not happen.
- `markdownImageSyntax` is the shared serializer of image markdown.
  `supportedImageMIMETypes` is the single source of extensions, picker types,
  and Preview MIME.
- Assets are deduplicated by content: size first, then bytes. Do not read every
  image fully without the size filter.
- For textbundle the disk defines existing assets; `assetsFileWrapper` is
  mirrored through `addImageAssetWrapper`. When picking a new name respect any
  `fileExists`, including hidden files and symlinks.
- The image viewer compares URL + `mtime` + size and reads the file in a
  detached task. A URL change clears the other file's image and shows loading;
  a reload of the same URL keeps the old image until the result. The check is
  opportunistic — on `updateNSView`, not via a file watcher.
- No synchronous disk I/O in `updateNSView`/SwiftUI `body`. Paste stays
  synchronous for the honest plain-text fallback, so its file scan must be
  minimal.

### Performance and UI

- Disk/Process/full diff never run on main and are not computed from a SwiftUI
  `body`. For folders, git, review anchors, and highlight use cache +
  background refresh.
- Highlight.js does not run blocking on every keystroke: the editor path uses
  cache/stale-while-revalidate; blocking is acceptable for one-off HTML/export.
- Light/dark is chosen at draw time: dynamic `NSColor`, both code palettes,
  formula tint. Do not bake the global `NSApp.effectiveAppearance` into window
  content.
- Line numbers are drawn in the left text inset, not in an `NSRulerView`.
  Strip/gutter geometry comes from `EditorFieldGeometry` and is not duplicated
  per mode.
- `NSTextView.isFlipped == true`. Reuse overlay views through a pool;
  add/remove subview from every layout pass creates a cycle.
- For Swift 6 AppKit delegate methods not annotated `@MainActor`, use
  `nonisolated` + `MainActor.assumeIsolated` only when AppKit guarantees the
  main thread.

### Localization

- The development language is English; all user-facing strings in code are
  English literals (SwiftUI keys or `String(localized:)` for plain
  String/AppKit). Russian lives as translations in
  `Resources/Localizable.xcstrings`.
- A new user-facing string must get a ru translation in the catalog; the
  translation's format specifiers must match the key (cast Int32 in
  interpolation to `Int`).
- MCP/control protocol messages and logs are not localized — agents read them.
- Language choice: Settings ▸ General ▸ Language writes `AppleLanguages` (see
  `AppLanguage.swift`), applied after restart. The test host forces en via the
  scheme argument `-AppleLanguages (en)` — string assertions are written in
  English.

### Preview, review, and integration

- Preview loads via `loadHTMLString`; schemeless local links are handled by the
  JS bridge. A vault-root path starts with `/`; an ordinary relative path is
  resolved from the document's folder.
- Settings of an active built-in plugin are edited in the "Properties" panel
  and change only registry-whitelisted frontmatter fields
  (`updateConfiguration`) through the ordinary undo path — no arbitrary YAML
  paths/ranges.
- The review sidecar preserves the smotr schema losslessly; offsets are UTF-16.
  Persist/reload is strictly FIFO; anchors are computed once off-main and
  cached.
- A physical path change first takes the `ReviewModel` FIFO permit, then
  without suspension sets the `AppState` gates and reserves in
  `DocumentRegistry` first all destinations, then all sources; completion must
  hand exact relocate/drop outcomes to all three coordinators.
- `openDiff` is a blocking tool: the continuation completes exactly once for
  Accept/Reject/close/disconnect/timeout.
- IDE/control services do not start under XCTest. The control router is
  two-phase: main state + deferred disk work; socket clients are concurrent and
  do not block main.
- The link-graph core (`LinkGraphEngine`, `WikiLinkCore`, persistence,
  vault-lint, search) also compiles into the `editmdctl` target (the offline
  engine): files on its list in `project.yml` must stay free of AppKit and app
  models. Wire shapes of vault-graph responses go only through the shared
  `ControlGraphPayload.swift`; the IDE MCP `tools/list` is not extended (the
  CLI aborts the handshake on unknown tools).

## Working rules

- All repository artifacts are in English: code comments, docs, commit
  messages. (The author is addressed in Russian in chat; the repo stays
  English.)
- Do not edit the generated `.xcodeproj` instead of `project.yml`.
- Do not mix unrelated changes and do not touch someone else's dirty worktree.
- Extract shared logic into testable pure/internal functions; paste routing and
  contextual guards must have direct tests.
- On a hang, first capture `sample <pid> 3`, then optimize the confirmed hot
  path.
- Durable new rules are added here briefly; detailed chronology and
  investigation write-ups go to the decision log outside the repo (ask the
  author where to record them until the docs redesign lands).

## Known tails

Wrapping of wide Visual-grid cells. (Find-in-Preview shipped in 0.47.0; remote
images in Visual and image drag-and-drop in 0.46.0.)
