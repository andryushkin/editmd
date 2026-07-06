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
    var theme: EditorTheme = .system
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
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = NSFont.monospacedSystemFont(
            ofSize: EditorFontSettings.shared.fontSize, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: theme.editorInsetH, height: theme.editorInsetV)

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
            selector: #selector(Coordinator.fontSizeDidChange),
            name: .editorFontSizeDidChange,
            object: nil
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard let textView = coordinator.textView else { return }
        textView.textContainerInset = NSSize(width: theme.editorInsetH, height: theme.editorInsetV)

        // Only update text if changed externally (not from typing)
        if !coordinator.isInternalUpdate, textView.string != document.content {
            textView.string = document.content
            coordinator.updateStats()
            coordinator.scheduleLint(delaySeconds: 0)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: SourceTextView
        fileprivate var textView: SourceNSTextView?
        var isInternalUpdate = false

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
            scheduleLint()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let textView {
                parent.positionStore?.markdownOffset = textView.selectedRange().location
            }
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
                makeFontBigger: { EditorFontSettings.shared.fontSize += 1 },
                makeFontSmaller: { EditorFontSettings.shared.fontSize -= 1 },
                canIncreaseFontSize: EditorFontSettings.shared.canIncrease,
                canDecreaseFontSize: EditorFontSettings.shared.canDecrease
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

        // MARK: Font size

        @objc func fontSizeDidChange() {
            guard let textView else { return }
            textView.font = NSFont.monospacedSystemFont(
                ofSize: EditorFontSettings.shared.fontSize, weight: .regular)
            publishActions()
        }
    }
}

// MARK: - Text view with lint quick-fixes in the context menu

fileprivate final class SourceNSTextView: NSTextView {

    var lintDiagnostics: [LintDiagnostic] = []
    private var menuFixes: [LintFix] = []

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
