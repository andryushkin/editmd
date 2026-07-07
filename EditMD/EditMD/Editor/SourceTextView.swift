import AppKit
import SwiftUI

// Source mode (v23): raw markdown in a plain monospaced NSTextView.
// No syntax highlighting or drawn decorations — the only intelligence here is
// the lint engine (MarkdownLint.swift): dotted underlines via layout-manager
// temporary attributes, quick-fixes in the context menu, a status-bar badge.
//
// Until v23 this lived in MarkdownTextView.swift together with the v17 hybrid
// live-preview engine; the hybrid died when Visual became true WYSIWYG (v21).

/// Lint state published to the status bar (Source mode).
struct LintSummary {
    var errorCount: Int
    var warningCount: Int
    var jumpToNext: () -> Void
}

struct SourceTextView: NSViewRepresentable {

    let document: MarkdownDocument
    /// Cursor continuity across modes (markdown offsets are native here).
    var positionStore: EditorPositionStore? = nil
    var onStatsUpdate: (Int, Int) -> Void
    var onFormatActions: (FormatActions) -> Void
    var onLintUpdate: ((LintSummary) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = SourceNSTextView()
        // Rich text so per-element highlighting (heading size/weight, colors)
        // renders. The document's source of truth is still the plain `.string`;
        // paste is forced to plain text so external rich content can't leak in.
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = EditorSettings.shared.source.resolvedFont(defaultMono: true)
        textView.textColor = EditorSettings.shared.effectiveTheme.textColor
        textView.insertionPointColor = EditorSettings.shared.effectiveTheme.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = EditorSettings.shared.source.textContainerInset(forWidth: scrollView.contentView.bounds.width)
        // Edit ▸ Find menu (⌘F & co.) drives the standard find bar.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scrollView.documentView = textView

        let coordinator = context.coordinator
        coordinator.textView = textView
        // Capture the cross-mode offset BEFORE any text/delegate wiring:
        // setting the string resets the selection, and the selection-change
        // callback would clobber the stored value with 0.
        let restoreOffset = positionStore?.markdownOffset
        textView.string = document.content
        textView.delegate = coordinator

        coordinator.updateStats()
        coordinator.publishActions()
        coordinator.highlightSource()
        coordinator.scheduleLint(delaySeconds: 0)

        if let store = positionStore, let restoreOffset {
            store.markdownOffset = restoreOffset
            let offset = min(restoreOffset, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: offset, length: 0))
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange())
                textView.centerSelectionInVisibleArea(nil)
                textView.window?.makeFirstResponder(textView)
            }
        }

        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.settingsDidChange),
            name: .editorSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        // Outline-sidebar jumps, object-scoped to this window's store (a nil
        // object would subscribe to every window's jumps).
        if let store = positionStore {
            NotificationCenter.default.addObserver(
                coordinator,
                selector: #selector(Coordinator.jumpToStoredOffset),
                name: .editMDJumpToOffset,
                object: store
            )
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard let textView = coordinator.textView else { return }
        textView.textContainerInset = EditorSettings.shared.source.textContainerInset(forWidth: scrollView.contentView.bounds.width)

        // External change (Revert, or another window editing the shared
        // document). A background window defers the reload until it becomes key
        // so its cursor/scroll survive edits made elsewhere.
        if !coordinator.isInternalUpdate, textView.string != document.content {
            if textView.window?.isKeyWindow ?? true {
                coordinator.reloadFromDocument()
            } else {
                coordinator.pendingExternalReload = true
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: SourceTextView
        fileprivate var textView: SourceNSTextView?
        var isInternalUpdate = false
        /// A background window sets this when the shared document changes under
        /// it; the reload is applied when the window next becomes key.
        var pendingExternalReload = false

        init(parent: SourceTextView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isInternalUpdate = true
            parent.document.content = tv.string
            isInternalUpdate = false
            updateStats()
            highlightSource()
            scheduleLint()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let textView {
                parent.positionStore?.markdownOffset = textView.selectedRange().location
            }
        }

        /// Outline-sidebar jump: markdown offsets are native here — place the
        /// cursor at the store's offset and reveal it (the same dance as the
        /// mode-switch restore in makeNSView).
        @objc func jumpToStoredOffset() {
            guard let textView, let store = parent.positionStore else { return }
            let offset = min(store.markdownOffset, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: offset, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
            textView.centerSelectionInVisibleArea(nil)
            textView.window?.makeFirstResponder(textView)
        }

        /// Reloads from the shared document (external change), preserving the
        /// cursor offset (clamped) across the swap.
        func reloadFromDocument() {
            guard let textView else { return }
            pendingExternalReload = false
            let sel = textView.selectedRange()
            textView.string = parent.document.content
            let len = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            updateStats()
            highlightSource()
            scheduleLint(delaySeconds: 0)
        }

        /// When a deferred external change is pending, apply it once the window
        /// regains focus (see updateNSView's background-window gate).
        @objc func windowBecameKey(_ note: Notification) {
            guard pendingExternalReload, let tv = textView,
                  (note.object as? NSWindow) === tv.window else { return }
            reloadFromDocument()
        }

        // MARK: Lint

        private var lintTask: Task<Void, Never>?
        private var lintDiagnostics: [LintDiagnostic] = []

        func scheduleLint(delaySeconds: Double = 0.3) {
            lintTask?.cancel()
            lintTask = Task { [weak self] in
                if delaySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                self?.runLint()
            }
        }

        private func runLint() {
            guard let textView else { return }
            let diags = lint(textView.string)
            lintDiagnostics = diags
            textView.lintDiagnostics = diags
            applyLintUnderlines(diags)
            let errors = diags.filter { $0.severity == .error }.count
            let summary = LintSummary(
                errorCount: errors,
                warningCount: diags.count - errors,
                jumpToNext: { [weak self] in self?.jumpToNextDiagnostic() }
            )
            DispatchQueue.main.async { [parent] in
                parent.onLintUpdate?(summary)
            }
        }

        /// Temporary attributes live in the layout manager only — they never
        /// touch NSTextStorage, so the document and undo stack stay clean.
        private func applyLintUnderlines(_ diags: [LintDiagnostic]) {
            guard let textView, let lm = textView.layoutManager else { return }
            let len = (textView.string as NSString).length
            let full = NSRange(location: 0, length: len)
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
            lm.removeTemporaryAttribute(.toolTip, forCharacterRange: full)
            for d in diags {
                guard d.range.location < len else { continue }
                let r = NSRange(location: d.range.location,
                                length: min(d.range.length, len - d.range.location))
                guard r.length > 0 else { continue }
                let color: NSColor = d.severity == .error ? .systemRed : .systemOrange
                lm.addTemporaryAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle([.single, .patternDot]).rawValue,
                    forCharacterRange: r)
                lm.addTemporaryAttribute(.underlineColor, value: color, forCharacterRange: r)
                lm.addTemporaryAttribute(.toolTip, value: d.message, forCharacterRange: r)
            }
        }

        private func jumpToNextDiagnostic() {
            guard let textView, !lintDiagnostics.isEmpty else { return }
            let cursor = textView.selectedRange().location
            let next = lintDiagnostics.first { $0.range.location > cursor } ?? lintDiagnostics[0]
            textView.setSelectedRange(next.range)
            textView.scrollRangeToVisible(next.range)
            textView.window?.makeFirstResponder(textView)
        }

        // MARK: Stats

        func updateStats() {
            guard let tv = textView else { return }
            let (words, chars) = wordAndCharCount(in: tv.string)
            DispatchQueue.main.async { [parent] in
                parent.onStatsUpdate(words, chars)
            }
        }

        // MARK: Format actions (marker wrapping — Source works on raw text)

        func publishActions() {
            let actions = FormatActions(
                toggleBold: { [weak self] in self?.wrapSelection(with: "**") },
                toggleItalic: { [weak self] in self?.wrapSelection(with: "*") },
                makeFontBigger: { EditorSettings.shared.adjustFontSize(\.source, by: 1) },
                makeFontSmaller: { EditorSettings.shared.adjustFontSize(\.source, by: -1) },
                canIncreaseFontSize: EditorSettings.shared.source.fontSize < ModeSettings.fontSizeRange.upperBound,
                canDecreaseFontSize: EditorSettings.shared.source.fontSize > ModeSettings.fontSizeRange.lowerBound,
                toggleStrikethrough: { [weak self] in self?.wrapSelection(with: "~~") },
                toggleCodeSpan: { [weak self] in self?.wrapSelection(with: "`") },
                setHeading: { [weak self] level in self?.transformSelectedLines(.heading(level)) },
                toggleBulletList: { [weak self] in self?.transformSelectedLines(.bullet) },
                toggleNumberedList: { [weak self] in self?.transformSelectedLines(.ordered) },
                toggleQuote: { [weak self] in self?.transformSelectedLines(.quote) },
                toggleCodeBlock: { [weak self] in self?.fenceSelectedLines() }
            )
            DispatchQueue.main.async { [parent] in
                parent.onFormatActions(actions)
            }
        }

        private func wrapSelection(with marker: String) {
            guard let textView else { return }
            let range = textView.selectedRange()
            let (_, newSelection) = applyWrap(marker: marker, to: textView.string, selection: range)
            let selected = (textView.string as NSString).substring(with: range)
            let wrapped = marker + selected + marker
            guard textView.shouldChangeText(in: range, replacementString: wrapped) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: wrapped)
            textView.didChangeText()
            textView.setSelectedRange(newSelection)
        }

        /// Replaces the lines the selection touches with `replacement`,
        /// keeping undo intact, and selects the replaced text.
        private func replaceSelectedLines(with replacement: (String) -> String) {
            guard let textView else { return }
            let nsText = textView.string as NSString
            let lineRange = nsText.lineRange(for: textView.selectedRange())
            let replaced = replacement(nsText.substring(with: lineRange))
            guard textView.shouldChangeText(in: lineRange, replacementString: replaced) else { return }
            textView.textStorage?.replaceCharacters(in: lineRange, with: replaced)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location,
                                              length: (replaced as NSString).length))
        }

        private func transformSelectedLines(_ transform: BlockTransform) {
            replaceSelectedLines { transformLines(transform, lines: $0) }
        }

        private func fenceSelectedLines() {
            replaceSelectedLines { fenceLines($0) }
        }

        // MARK: Settings

        @objc func settingsDidChange() {
            guard let textView else { return }
            let settings = EditorSettings.shared.source
            textView.font = settings.resolvedFont(defaultMono: true)
            textView.insertionPointColor = EditorSettings.shared.effectiveTheme.textColor
            textView.textContainerInset = settings.textContainerInset(
                forWidth: textView.enclosingScrollView?.contentView.bounds.width ?? 0)
            highlightSource()
            publishActions()
        }

        // MARK: Source highlighting

        /// Re-styles the raw markdown from `collectSpans` + the Source mode's
        /// per-element settings. Real text-storage attributes (not temporary
        /// ones) so heading size changes take effect; the plain `.string` — the
        /// document's source of truth — is untouched, and attribute-only edits
        /// don't register undo. Two passes: block-level (heading lines, quotes)
        /// then inline (bold/code/link/italic/strike) so inline overrides win.
        func highlightSource() {
            guard let textView, let storage = textView.textStorage else { return }
            let settings = EditorSettings.shared.source
            let theme = EditorSettings.shared.effectiveTheme
            let els = settings.elements
            let baseFont = settings.resolvedFont(defaultMono: true)
            let nsText = textView.string as NSString
            let full = NSRange(location: 0, length: nsText.length)
            let spans = collectSpans(textView.string)

            func headingFont(_ level: Int) -> NSFont {
                let e = els.heading(level)
                return sourceFont(size: settings.fontSize * e.sizeScale,
                                  weight: (e.weight ?? .semibold).nsWeight)
            }

            storage.beginEditing()
            storage.setAttributes([.font: baseFont, .foregroundColor: theme.textColor], range: full)

            // Pass A — block level.
            for span in spans where NSMaxRange(span.range) <= full.length {
                switch span.kind {
                case .headingBody(let level):
                    let line = nsText.lineRange(for: span.range)
                    storage.addAttribute(.font, value: headingFont(level), range: line)
                    if let c = els.heading(level).color {
                        storage.addAttribute(.foregroundColor, value: c, range: line)
                    }
                case .quoteBody, .quoteMarker:
                    if let c = els.quote.color {
                        storage.addAttribute(.foregroundColor, value: c, range: span.range)
                    }
                default:
                    break
                }
            }

            // Pass B — inline.
            for span in spans where NSMaxRange(span.range) <= full.length {
                switch span.kind {
                case .boldBody, .boldMarker:
                    let existing = storage.attribute(.font, at: span.range.location,
                                                     effectiveRange: nil) as? NSFont ?? baseFont
                    storage.addAttribute(.font, value: sourceFont(
                        size: existing.pointSize, weight: (els.bold.weight ?? .bold).nsWeight),
                                         range: span.range)
                    if let c = els.bold.color {
                        storage.addAttribute(.foregroundColor, value: c, range: span.range)
                    }
                case .italicBody:
                    let existing = storage.attribute(.font, at: span.range.location,
                                                     effectiveRange: nil) as? NSFont ?? baseFont
                    if let italic = existing.withSourceTraits(.italic) {
                        storage.addAttribute(.font, value: italic, range: span.range)
                    }
                case .code, .codeMarker:
                    if let c = els.inlineCode.color {
                        storage.addAttribute(.foregroundColor, value: c, range: span.range)
                    }
                case .linkText:
                    if let c = els.link.color {
                        storage.addAttribute(.foregroundColor, value: c, range: span.range)
                    }
                case .strikethroughBody:
                    storage.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue, range: span.range)
                default:
                    break
                }
            }
            storage.endEditing()
        }

        /// A Source font honoring the mode's family (else system mono) at an
        /// explicit size/weight.
        private func sourceFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
            let family = EditorSettings.shared.source.fontFamily
            if !family.isEmpty {
                let descriptor = NSFontDescriptor(fontAttributes: [
                    .family: family,
                    .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
                ])
                if let font = NSFont(descriptor: descriptor, size: size) { return font }
            }
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
    }
}

// MARK: - Text view with lint quick-fixes in the context menu

fileprivate extension NSFont {
    func withSourceTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
        let combined = fontDescriptor.symbolicTraits.union(traits)
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(combined), size: pointSize)
    }
}

fileprivate final class SourceNSTextView: NSTextView {

    var lintDiagnostics: [LintDiagnostic] = []
    private var menuFixes: [LintFix] = []

    // Paste as plain text — rich content from the clipboard would introduce
    // attributes the highlighter doesn't own (isRichText is on only so our
    // own per-element attributes render).
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, !lintDiagnostics.isEmpty else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        guard let idx = characterIndex(at: point) else { return menu }
        let hits = lintDiagnostics.filter { NSLocationInRange(idx, $0.range) }
        guard !hits.isEmpty else { return menu }

        menuFixes = []
        var insertAt = 0
        for diagnostic in hits {
            // action == nil → the item auto-disables; serves as a header.
            let header = NSMenuItem(title: diagnostic.message, action: nil, keyEquivalent: "")
            menu.insertItem(header, at: insertAt)
            insertAt += 1
            for fix in diagnostic.fixes {
                let item = NSMenuItem(title: fix.title,
                                      action: #selector(applyLintFix(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = menuFixes.count
                item.indentationLevel = 1
                menuFixes.append(fix)
                menu.insertItem(item, at: insertAt)
                insertAt += 1
            }
        }
        menu.insertItem(.separator(), at: insertAt)
        return menu
    }

    @objc private func applyLintFix(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < menuFixes.count else { return }
        let fix = menuFixes[sender.tag]
        guard NSMaxRange(fix.range) <= (string as NSString).length else { return }
        guard shouldChangeText(in: fix.range, replacementString: fix.replacement) else { return }
        textStorage?.replaceCharacters(in: fix.range, with: fix.replacement)
        didChangeText()
    }

    /// Character index under the view-coordinate point, or nil when the point
    /// falls outside any glyph.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }
}
