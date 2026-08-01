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

Source-editor contracts:

- Source aligns tables **display-only** via the `.kern` attribute: the
  markdown bytes never change, and `.kern` must be stripped from typing
  attributes so it cannot leak into typed text.
- `textView.string = …` and `setAttributedString` synchronously invoke the
  selection delegate — read the caret position *before* replacing content.
- Presentation attributes that affect layout must be storage attributes;
  transient washes (review highlight) use temporary layout-manager attributes
  that never touch the storage.

Preview specifics: the page loads via `loadHTMLString` (no file base URL);
schemeless local links are routed through the JS bridge — a path starting with
`/` resolves from the vault root, a plain relative path from the document's
folder. KaTeX is bundled offline (`Resources/katex/`), so the page needs no
network.

## Async editor state

Caret-format state (`ActiveInlineFormats`) reaches the action strip through an
async hop in every mode — Source/Visual via a main-queue dispatch, Preview via
the WKWebView script-message queue — so a value computed before a mode switch
can land after the switch reset the shared state. `Views/ActiveFormatsGate.swift`
is the epoch gate that drops such stale publishes:

- Every publisher sink is stamped with the epoch current at render;
  `advance()` retires all sinks of the outgoing editor.
- `noteMode(mode)` is called at the top of `editorArea`, **strictly before any
  sink of that render pass is built**. Running inside view evaluation is what
  guarantees the order "advance, then build this pass's sinks"; an
  `.onChange` bump cannot (its ordering against child `body` evaluation is
  unspecified and a late bump would retire fresh sinks).
- The render-time funnel catches *every* writer of the shared mode default —
  the strip and menus go through `setEditorMode`, but the control socket
  (`editmdctl mode …`) writes UserDefaults directly and would otherwise never
  advance the gate.
- A file switch needs no epoch of its own: `.id(url)` recreates `ContentView`
  and deallocates the gate; the weak reference in each sink drops late
  publishes the same way.

## Action strip

`Views/EditorActionStrip.swift` plans its layout through testable value types
(`StripLayoutItem`, `StripCommandNode`). Non-negotiables:

- **Availability invariant**: window width never changes the *set* of
  reachable commands. Degradation is two-stage — a group first compacts into a
  single submenu button, then folds into the trailing "…" menu — and every
  command stays reachable in every stage (the flatten of the command tree is
  the proof surface, covered by tests).
- The terminal (lane-alone) overflow pill is **wider** than the inline "…"
  (icon + chevron), and the planner accounts for the two widths separately.
- Widths are reserved by the widest state of a group so a degradation-level
  change never causes a replan loop; a folded group still needs a measured
  width or it could never come back.
- Gutter-owned controls belong to the gutter lane and never collapse into "…";
  the mode switcher is never overlapped.

## Menus and AppKit panels

Two rules keep the keyboard alive inside the app's AppKit dialogs (the ⌘K link
editor, the folder/file name prompts) — both were learned the hard way:

- The Edit menu's Cut / Copy / Paste / Select All stay **stock** SwiftUI items.
  Re-implementing them as SwiftUI `Button`s that send the same standard
  selectors looks equivalent but is not: while an AppKit panel is the key
  window, SwiftUI validates its own menu items as disabled and yet still
  swallows their key equivalents, so ⌘V does nothing anywhere in a dialog. A
  stock nil-target `paste:` item revalidates against the real responder chain
  and reaches the panel's field editor. The same trap applies to any command
  whose shortcut a dialog needs: ⌘Z is still ours, so it is inert inside a
  dialog — measured inert, not dangerous, the disabled item does not fire the
  document's undo either.
- An alert with a text field is built and run through `Views/AlertFields.swift`:
  `alertTextField(width:)` for the field, `runModal(_:focusing:)` instead of
  `alert.runModal()`. Two things there are ours because AppKit's do not work in
  our alerts — `window.initialFirstResponder` is overridden while the panel
  becomes key (so focus is claimed from `didBecomeKey`, then briefly re-claimed,
  since AppKit's own pass can run after it), and the bezel of an unfocused field
  is not painted at all (so the resting box is drawn by the field's layer). Both
  are app-specific: an isolated alert built from the same code behaves, which is
  why the workarounds are aimed at the symptoms.

## Mouse cursor over the pane dividers

`PaneDivider`'s 14pt grab strip overhangs its neighbours, and its ↔ competes
with whatever they publish. **This is unfinished work, not a settled contract**
— the strip is an AppKit view publishing its own cursor rect, attached to the
pane container by `paneGrabStrip`, and the zone is still one-sided. What follows
is what has been measured so far.

Mechanism, as far as it was established:

- There is no priority ladder. Cursor rects, tracking-area cursor updates and
  `NSCursor.set` all end in the same place, and the **last write for that event
  wins**. Arbitration starts from the deepest view the pointer HIT-TESTS to.
- `.cursorUpdate` on a tracking area fires on enter and exit, not per move, so
  it cannot hold against a neighbour that publishes per move.
- An `NSView` in a SwiftUI branch that overhangs its parent (the strip inside an
  overlay on the 1pt line) is not reliably reached by `hitTest`, at any
  `zIndex`. The strip now hangs off the whole pane container instead, which
  removes that objection — yet the zone stayed one-sided, and THAT is where the
  next session has to start: measure the strip's frame and `contentView.hitTest`
  at points either side of the line before changing anything else.
- `WKWebView` publishes nothing over blank regions, so a ↔ set over it simply
  stays until someone else writes — this is what "the zone extends far to the
  right" actually was, not a wider strip. It is also never the view `hitTest`
  returns: it hit-tests to its own content view. Both facts make it the wrong
  thing to protect on the way out — nothing publishes over blank regions, so a
  ↔ left for it stays for good, while over content WebKit publishes per move
  and overwrites the arrow anyway. Only a text view keeps the arrow away, and
  it is looked for among the hit view's ANCESTORS, not in the leaf. The
  residual risk is accepted, not overlooked: if WebKit publishes before the
  strip's `mouseExited`, crossing onto Preview content and stopping shows the
  arrow until the next move — which clears itself, unlike a stuck ↔.

Being opaque to the pointer costs the strip two things it has to hand back:

- the wheel — the pane under the strip is a SIBLING subtree, so the default
  responder walk never reaches its scroll view and the event would die.
  `scrollWheel` re-hit-tests with the strip made transparent for that one call
  and forwards to whoever is behind it;
- the plain click — a press with no movement is not a resize, and reporting
  from `mouseDown` committed the pointer's x as the new pane width, so
  clicking a row the strip overhangs nudged the pane. Only `mouseDragged`
  reports — from the grab offset the press recorded (`dividerLineX`), so
  grabbing the strip's edge moves the divider BY the pointer instead of
  snapping the line under it on the first drag.

Dead ends, all confirmed by hand:

- Cursor rects added inside `VisualNSTextView` (before or after `super`) never
  produce the pointing hand at all. `NSTextView` does not yield that channel;
  the ⌘-link hand and the table-row open hand must use imperative
  `NSCursor.set`, re-asserted on every `mouseMoved` / `flagsChanged` while the
  affordance is live (otherwise the I-beam from the text view's own rects
  overwrites the hand on the next move and the cursor flickers).
- Making the strip transparent to hit testing (f32f4b9) drops it out of cursor
  resolution entirely.
- Reserving the strip's 14pt in layout removes the overlap and the flicker with
  it, but narrows both panes.

The ⌘-hover flicker under small VERTICAL moves has a separate, non-AppKit
cause (fixed in `linkRun(hitAt:)`): picking the candidate from
`glyphIndex(for:)` snaps to the NEAREST glyph and jumps to the line above or
below while the pointer is still inside the link's own line fragment; the run
then resolves to nil and the hover drops. The hit is resolved from the link
runs' own rects instead (`visualRunRects`: one per line fragment, glyph box
horizontally, used height vertically — `lineSpacing`, `minimumLineHeight` and
`lineHeightMultiple` land inside it; paragraph spacing does not, and should
not: the gap between two blocks belongs to neither). That selection step is independent
of the cursor-channel rule above — both are required for a stable pointing
hand.

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
Assets are deduplicated by content — size check first, then bytes. For
textbundle documents the disk defines which assets exist and
`assetsFileWrapper` is mirrored through `addImageAssetWrapper`; when choosing
a fresh asset name, any `fileExists` counts — including hidden files and
symlinks.

The image viewer (`Views/PDFViewerView.swift` and friends) revalidates by
URL + `mtime` + size and reads files in a detached task. A URL change clears
the previous image and shows loading; reloading the same URL keeps the old
image until the new bytes arrive. The check is opportunistic — on
`updateNSView`, not via a file watcher.

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
`Resources/Localizable.xcstrings`; the usage descriptions macOS shows in its
own permission prompts live in `Resources/InfoPlist.xcstrings`, keyed by
`Info.plist` key. Protocol messages and logs are not
localized — agents read them. Settings ▸ General ▸ Language writes
`AppleLanguages` (see `Views/AppLanguage.swift`); the test host forces English
with the scheme argument `-AppleLanguages (en)`.
