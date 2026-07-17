import AppKit

// Format actions for Visual (WYSIWYG) mode — toolbar / Format-menu / action-strip
// entry points on VisualMarkdownView.Coordinator. Split out of VisualTextView.swift
// when it passed 2600 lines; the editing core (delegate, tables, Enter/Tab) stays there.

extension VisualMarkdownView.Coordinator {
    // MARK: Format actions

    func publishActions() {
        let actions = FormatActions(
            toggleBold: { [weak self] in self?.toggleInlineStyle(.bold) },
            toggleItalic: { [weak self] in self?.toggleInlineStyle(.italic) },
            makeFontBigger: { EditorSettings.shared.adjustFontSize(\.visual, by: 1) },
            makeFontSmaller: { EditorSettings.shared.adjustFontSize(\.visual, by: -1) },
            canIncreaseFontSize: EditorSettings.shared.visual.fontSize < ModeSettings.fontSizeRange.upperBound,
            canDecreaseFontSize: EditorSettings.shared.visual.fontSize > ModeSettings.fontSizeRange.lowerBound,
            toggleChecklist: { [weak self] in self?.toggleChecklist() },
            editLink: { [weak self] in self?.editLink() },
            toggleStrikethrough: { [weak self] in self?.toggleInlineStyle(.strike) },
            toggleCodeSpan: { [weak self] in self?.toggleInlineStyle(.code) },
            toggleHighlight: { [weak self] in self?.toggleInlineStyle(.highlight) },
            setHeading: { [weak self] level in self?.setHeading(level) },
            setBody: { [weak self] in self?.setBodyParagraph() },
            clearInlineFormatting: { [weak self] in self?.clearInlineFormatting() },
            insertDivider: { [weak self] in self?.insertDivider() },
            insertImage: { [weak self] in self?.chooseAndInsertImage() },
            cycleCase: { [weak self] in self?.cycleSelectionCase() },
            toggleBulletList: { [weak self] in self?.toggleListKind(
                isTarget: { if case .bulletItem = $0 { return true }; return false },
                makeKind: { .bulletItem(depth: $0) }) },
            toggleNumberedList: { [weak self] in self?.toggleListKind(
                isTarget: { if case .orderedItem = $0 { return true }; return false },
                makeKind: { .orderedItem(depth: $0, number: 1) }) },
            toggleQuote: { [weak self] in self?.toggleQuote() },
            toggleCodeBlock: { [weak self] in self?.toggleCodeBlock() },
            insertTable: { [weak self] in self?.insertEmptyTable() },
            tableAddRow: { [weak self] in self?.tableAddRowAtCursor() },
            tableDeleteRow: { [weak self] in self?.tableDeleteRowAtCursor() },
            tableAddColumn: { [weak self] in self?.tableAddColumnAtCursor() },
            tableDeleteColumn: { [weak self] in self?.tableDeleteColumnAtCursor() },
            insertInlineFormula: { [weak self] in self?.insertFormulaTemplate(display: false) },
            insertBlockFormula: { [weak self] in self?.insertFormulaTemplate(display: true) }
        )
        DispatchQueue.main.async { [parent] in
            parent.onFormatActions(actions)
        }
    }

    private func setBodyParagraph() {
        guard let textView, let storage = textView.textStorage else { return }
        var paragraphs = selectedParagraphs()
        // Caret with empty selection still demotes the current paragraph.
        if paragraphs.isEmpty, storage.length > 0 {
            let nsText = storage.string as NSString
            let p = paragraphRange(at: textView.selectedRange().location, in: nsText)
            switch block(at: p, in: storage).kind {
            case .tableCell, .raw: break
            default: paragraphs = [p]
            }
        }
        guard !paragraphs.isEmpty else { NSSound.beep(); return }
        for paragraph in paragraphs {
            var target = block(at: paragraph, in: storage)
            target.kind = .paragraph
            target.group = -1
            target.quoteDepth = 0
            target.quoteGroup = -1
            restamp(paragraph, to: target, in: textView)
        }
    }

    /// Strip inline md.* styles on the selection; leave block kind alone (B4).
    private func clearInlineFormatting() {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0 else {
            // Caret: clear typing attrs only.
            var attrs = textView.typingAttributes
            attrs[.mdInline] = nil
            let blockAttr = attrs[.mdBlock] as? MDBlock ?? MDBlock(kind: .paragraph)
            attrs[.font] = visualStyle.font(for: [], blockKind: blockAttr.kind)
            textView.typingAttributes = attrs
            return
        }
        guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
        isMutating = true
        storage.beginEditing()
        storage.enumerateAttributes(in: selection) { attrs, range, _ in
            storage.removeAttribute(.mdInline, range: range)
            let blockAttr = attrs[.mdBlock] as? MDBlock ?? MDBlock(kind: .paragraph)
            storage.addAttribute(.font,
                                 value: self.visualStyle.font(for: [], blockKind: blockAttr.kind),
                                 range: range)
            storage.removeAttribute(.strikethroughStyle, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
        }
        storage.endEditing()
        isMutating = false
        textView.didChangeText()
        afterMutation()
    }

    /// Insert thematic break as a rendered block (same path as empty table).
    private func insertDivider() {
        guard let textView, let storage = textView.textStorage else { return }
        let md = "\n\n---\n\n"
        let rendered = renderForInsertion(md, into: storage)
        let selection = textView.selectedRange()
        guard textView.shouldChangeText(in: selection, replacementString: rendered.string)
        else { return }
        isMutating = true
        storage.replaceCharacters(in: selection, with: rendered)
        isMutating = false
        textView.didChangeText()
        afterMutation()
    }

    private func chooseAndInsertImage() {
        guard allowsImageInsertionAtSelection() else {
            NSSound.beep()
            return
        }
        guard let asset = chooseImageForInsertion(document: parent.document,
                                                   fileURL: parent.fileURL) else { return }
        insertImage(asset)
    }

    /// Clipboard-image fallback after Visual's table/Markdown paste door.
    /// Returning true suppresses the plain-text fallback for binary payloads.
    func pasteImageFromPasteboard() -> Bool {
        guard allowsImageInsertionAtSelection() else { return false }
        guard let candidate = imageCandidate(from: .general) else { return false }
        do {
            let asset = try storeImageAsset(candidate, document: parent.document,
                                            fileURL: parent.fileURL)
            insertImage(asset)
        } catch {
            presentImageInsertionError(error)
            return false
        }
        return true
    }

    /// Drop of an image file / bitmap onto the Visual view: same store +
    /// render path as paste, at the already-positioned caret. False when the
    /// drop context forbids images or the image can't be stored (the view then
    /// leaves the drop to the default handling).
    func insertDraggedImage(_ candidate: ImageAssetCandidate) -> Bool {
        guard allowsImageInsertionAtSelection() else { return false }
        do {
            let asset = try storeImageAsset(candidate, document: parent.document,
                                            fileURL: parent.fileURL)
            insertImage(asset)
        } catch {
            presentImageInsertionError(error)
            return false
        }
        return true
    }

    /// Images are structural attributed runs. Literal/raw islands serialize
    /// their original `.raw` payload and table cells are single-line, so none
    /// of those contexts may accept an image attachment.
    private func allowsImageInsertionAtSelection() -> Bool {
        guard let kind = pasteBlockKindAtSelection() else { return true }
        return visualContextAllowsStructuredPaste(kind)
    }

    private func insertImage(_ asset: ImageInsertionAsset) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let selected = selection.length > 0
            ? (storage.string as NSString).substring(with: selection) : nil
        let usableAlt = selected?.contains(where: { $0.isNewline || $0 == "\u{FFFC}" })
            == false ? selected : nil
        let rendered = renderForInsertion(asset.markdown(alt: usableAlt), into: storage)
        guard textView.shouldChangeText(in: selection, replacementString: rendered.string)
        else { return }
        isMutating = true
        storage.replaceCharacters(in: selection, with: rendered)
        isMutating = false
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: selection.location + rendered.length, length: 0))
        afterMutation()
    }

    /// Inserts a formula at the caret (or wraps the selection as the TeX
    /// body) and immediately opens the popover editor on it. The formula is
    /// a rendered SwiftMath attachment carrying the verbatim source in
    /// `.mdMathTex`; when the TeX doesn't parse it stays a tinted raw run.
    private func insertFormulaTemplate(display: Bool) {
        guard let textView else { return }
        let selection = textView.selectedRange()
        var inner = selection.length > 0
            ? (textView.string as NSString).substring(with: selection)
            : (display ? "E = mc^2" : "x")
        if !display {
            inner = inner.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: mdHardBreak, with: " ")
        }
        replaceFormula(in: selection, tex: inner, display: display)
        editFormula(at: selection.location)
    }

    /// Opens the popover editor when `charIndex` is a rendered formula
    /// attachment. Returns false when it isn't (caller falls through).
    @discardableResult
    func editFormula(at charIndex: Int) -> Bool {
        guard let textView, let storage = textView.textStorage,
              charIndex >= 0, charIndex < storage.length,
              let verbatim = storage.attribute(.mdMathTex, at: charIndex,
                                               effectiveRange: nil) as? String
        else { return false }
        let display = (storage.attribute(.mdMath, at: charIndex,
                                         effectiveRange: nil) as? Int ?? 0) == 1
        let font = storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont
        MathEditorPopover.present(
            over: textView,
            charRange: NSRange(location: charIndex, length: 1),
            tex: MathRender.innerTeX(of: verbatim),
            display: display,
            fontSize: font?.pointSize ?? EditorSettings.shared.visual.fontSize
        ) { [weak self] newTeX in
            guard let self, let textView = self.textView,
                  let storage = textView.textStorage else { return }
            // The document may have changed while the popover was open —
            // only apply when the attachment is still the same formula.
            guard charIndex < storage.length,
                  (storage.attribute(.mdMathTex, at: charIndex,
                                     effectiveRange: nil) as? String) == verbatim
            else { NSSound.beep(); return }
            let trimmed = newTeX.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                self.removeRun(at: NSRange(location: charIndex, length: 1))
            } else {
                self.replaceFormula(in: NSRange(location: charIndex, length: 1),
                                    tex: newTeX, display: display)
            }
        }
        return true
    }

    /// Replaces `range` with a formula run built from `tex` (rendered
    /// attachment when it parses, tinted verbatim text otherwise). Undoable.
    private func replaceFormula(in range: NSRange, tex: String, display: Bool) {
        guard let textView, let storage = textView.textStorage else { return }
        let cleaned = display
            ? tex.trimmingCharacters(in: .whitespacesAndNewlines)
            : tex.trimmingCharacters(in: .whitespaces)
        let verbatim = MathRender.verbatim(tex: cleaned, display: display)
        var attrs = range.location < storage.length
            ? storage.attributes(at: range.location, effectiveRange: nil)
            : textView.typingAttributes
        // A formula must not inherit unrelated inline semantics from the
        // insertion point.
        for key: NSAttributedString.Key in [.attachment, .mdMathTex, .mdLink,
                                            .mdWikiLink, .mdImage, .mdInline] {
            attrs.removeValue(forKey: key)
        }
        attrs[.mdMath] = display ? 1 : 0
        let fontSize = (attrs[.font] as? NSFont)?.pointSize
            ?? EditorSettings.shared.visual.fontSize
        let replacement: NSAttributedString
        if let attachment = MathRender.attachment(tex: cleaned, display: display,
                                                  fontSize: fontSize) {
            attrs[.mdMathTex] = verbatim
            let run = NSMutableAttributedString(attachment: attachment)
            run.addAttributes(attrs, range: NSRange(location: 0, length: run.length))
            replacement = run
        } else {
            replacement = NSAttributedString(
                string: verbatim.replacingOccurrences(of: "\n", with: mdHardBreak),
                attributes: attrs)
        }
        guard textView.shouldChangeText(in: range, replacementString: replacement.string)
        else { return }
        isMutating = true
        storage.replaceCharacters(in: range, with: replacement)
        isMutating = false
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + replacement.length,
                                          length: 0))
        afterMutation()
    }

    /// Deletes a run (empty TeX committed from the popover = remove formula).
    private func removeRun(at range: NSRange) {
        guard let textView, let storage = textView.textStorage,
              NSMaxRange(range) <= storage.length else { return }
        guard textView.shouldChangeText(in: range, replacementString: "") else { return }
        isMutating = true
        storage.replaceCharacters(in: range, with: "")
        isMutating = false
        textView.didChangeText()
        afterMutation()
    }

    private func cycleSelectionCase() {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0 else { NSSound.beep(); return }
        // Run-by-run transform: a plain-String replaceCharacters would smear
        // the first run's attributes over a mixed-format selection.
        let next = cycleCaseAttributed(storage.attributedSubstring(from: selection))
        guard next.string != (storage.string as NSString).substring(with: selection) else { return }
        guard textView.shouldChangeText(in: selection, replacementString: next.string) else { return }
        isMutating = true
        storage.replaceCharacters(in: selection, with: next)
        isMutating = false
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: selection.location,
                                          length: next.length))
        afterMutation()
    }

    private func insertEmptyTable() {
        guard let textView, let storage = textView.textStorage else { return }
        let md = """
        |   |   |   |
        | --- | --- | --- |
        |   |   |   |
        |   |   |   |

        """
        let rendered = renderForInsertion(md, into: storage)
        let selection = textView.selectedRange()
        guard textView.shouldChangeText(in: selection, replacementString: rendered.string)
        else { return }
        isMutating = true
        storage.replaceCharacters(in: selection, with: rendered)
        isMutating = false
        textView.didChangeText()
        afterMutation()
    }

    private func tableAddRowAtCursor() {
        guard let textView, let storage = textView.textStorage else { return }
        let caret = textView.selectedRange().location
        // Native table: insert below the cursor's row (cursor follows).
        if let target = nativeTableTarget(atCharIndex: caret),
           performTableOp(.insertRowBelow, on: target) {
            return
        }
        // Large-table island: append a body row (no caret inside islands).
        let paragraph = paragraphRange(at: caret, in: storage.string as NSString)
        if let island = tableIsland(at: paragraph.location) {
            let at = island.grid.rows.count
            if insertTableIslandRow(paragraphLocation: paragraph.location, atBodyIndex: at) {
                return
            }
        }
        NSSound.beep()
    }

    private func tableDeleteRowAtCursor() {
        guard let textView, let storage = textView.textStorage else { return }
        let caret = textView.selectedRange().location
        // Native table: delete the cursor's row (header stays).
        if let target = nativeTableTarget(atCharIndex: caret) {
            if !performTableOp(.deleteRow, on: target) { NSSound.beep() }
            return
        }
        let paragraph = paragraphRange(at: caret, in: storage.string as NSString)
        if let island = tableIsland(at: paragraph.location), !island.grid.rows.isEmpty {
            let last = island.grid.rows.count - 1
            if deleteTableIslandRow(paragraphLocation: paragraph.location, atBodyIndex: last) {
                return
            }
        }
        NSSound.beep()
    }

    private func tableAddColumnAtCursor() {
        guard let textView, let storage = textView.textStorage else { return }
        let caret = textView.selectedRange().location
        // Native table: insert to the right of the cursor's column (caret follows).
        if let target = nativeTableTarget(atCharIndex: caret),
           performTableOp(.insertColumnRight, on: target) {
            return
        }
        // Large-table island: append a column at the right edge.
        let paragraph = paragraphRange(at: caret, in: storage.string as NSString)
        if let island = tableIsland(at: paragraph.location) {
            let at = island.grid.columnCount
            if mutateTableIsland(at: paragraph.location, { $0.insertColumn(at: at); return true }) {
                return
            }
        }
        NSSound.beep()
    }

    private func tableDeleteColumnAtCursor() {
        guard let textView, let storage = textView.textStorage else { return }
        let caret = textView.selectedRange().location
        // Native table: delete the cursor's column (the ≥1-column floor beeps).
        if let target = nativeTableTarget(atCharIndex: caret) {
            if !performTableOp(.deleteColumn, on: target) { NSSound.beep() }
            return
        }
        let paragraph = paragraphRange(at: caret, in: storage.string as NSString)
        if let island = tableIsland(at: paragraph.location), island.grid.columnCount > 1 {
            let last = island.grid.columnCount - 1
            if mutateTableIsland(at: paragraph.location, { $0.deleteColumn(at: last) }) {
                return
            }
        }
        NSSound.beep()
    }

    private func toggleInlineStyle(_ style: MDInlineStyle) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        if selection.length == 0 {
            var attrs = textView.typingAttributes
            var styles = MDInlineStyle(rawValue: attrs[.mdInline] as? Int ?? 0)
            styles.formSymmetricDifference(style)
            attrs[.mdInline] = styles.isEmpty ? nil : styles.rawValue
            let blockAttr = attrs[.mdBlock] as? MDBlock ?? MDBlock(kind: .paragraph)
            attrs[.font] = visualStyle.font(for: styles, blockKind: blockAttr.kind)
            textView.typingAttributes = attrs
            return
        }

        // Add the style unless every character already has it.
        var allHave = true
        storage.enumerateAttribute(.mdInline, in: selection) { value, _, stop in
            let styles = MDInlineStyle(rawValue: value as? Int ?? 0)
            if !styles.contains(style) { allHave = false; stop.pointee = true }
        }
        guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
        isMutating = true
        storage.beginEditing()
        storage.enumerateAttributes(in: selection) { attrs, range, _ in
            var styles = MDInlineStyle(rawValue: attrs[.mdInline] as? Int ?? 0)
            if allHave { styles.remove(style) } else { styles.insert(style) }
            if styles.isEmpty {
                storage.removeAttribute(.mdInline, range: range)
            } else {
                storage.addAttribute(.mdInline, value: styles.rawValue, range: range)
            }
            let blockAttr = attrs[.mdBlock] as? MDBlock ?? MDBlock(kind: .paragraph)
            storage.addAttribute(.font,
                                 value: self.visualStyle.font(for: styles, blockKind: blockAttr.kind),
                                 range: range)
        }
        storage.endEditing()
        isMutating = false
        textView.didChangeText()
        afterMutation()
    }

    func toggleChecklist() {
        let initialPluginPayload = builtInPluginSnapshot.initialChecklistPayload
        toggleListKind(
            isTarget: isChecklistKind,
            makeKind: {
                checklistKind(depth: $0,
                              initialPluginPayload: initialPluginPayload)
            })
    }

    /// Paragraph ranges the selection touches (skipping none); table
    /// cells and raw islands are excluded — block restamps would corrupt
    /// them.
    func selectedParagraphs() -> [NSRange] {
        guard let textView, let storage = textView.textStorage else { return [] }
        let nsText = storage.string as NSString
        let selection = textView.selectedRange()
        var location = paragraphRange(at: selection.location, in: nsText).location
        let selectionEnd = max(NSMaxRange(selection), location + 1)

        var paragraphs: [NSRange] = []
        while location < selectionEnd && location <= nsText.length {
            let paragraph = paragraphRange(at: location, in: nsText)
            switch block(at: paragraph, in: storage).kind {
            case .tableCell, .raw:
                break
            default:
                paragraphs.append(paragraph)
            }
            if NSMaxRange(paragraph) == location { break }
            location = NSMaxRange(paragraph)
        }
        return paragraphs
    }

    /// Shared list toggle (bullet/ordered/task): if every selected
    /// paragraph already is the target kind, all flatten to paragraphs;
    /// otherwise each becomes the target kind — existing list depth
    /// survives, plain paragraphs enter at depth 0 in one new group.
    func toggleListKind(isTarget: (MDBlock.Kind) -> Bool,
                        makeKind: (Int) -> MDBlock.Kind) {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphs = selectedParagraphs()
        guard !paragraphs.isEmpty else { return }

        let allTarget = paragraphs.allSatisfy { isTarget(block(at: $0, in: storage).kind) }
        let group = uniqueGroup(in: storage)
        for paragraph in paragraphs {
            var target = block(at: paragraph, in: storage)
            if allTarget {
                target.kind = .paragraph
                target.group = -1
            } else {
                let depth: Int
                switch target.kind {
                case .bulletItem(let d), .orderedItem(let d, _), .taskItem(let d, _),
                     .builtInPluginTaskItem(let d, _):
                    depth = d
                default:
                    depth = 0
                }
                if !isTarget(target.kind) {
                    target.kind = makeKind(depth)
                    if target.group < 0 { target.group = group }
                }
            }
            restamp(paragraph, to: target, in: textView)
        }
    }

    /// Heading level 1…6 on the selected paragraphs; the same level again
    /// turns them back into plain paragraphs.
    func setHeading(_ level: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphs = selectedParagraphs()
        guard !paragraphs.isEmpty else { return }

        let allMatch = paragraphs.allSatisfy {
            block(at: $0, in: storage).kind == .heading(level)
        }
        for paragraph in paragraphs {
            var target = block(at: paragraph, in: storage)
            target.kind = allMatch ? .paragraph : .heading(level)
            target.group = -1
            restamp(paragraph, to: target, in: textView)
        }
    }

    /// Quote is orthogonal to the block kind (quoteDepth/quoteGroup):
    /// unquoted paragraphs join one new quote group, fully quoted
    /// selections lose the quote.
    func toggleQuote() {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphs = selectedParagraphs()
        guard !paragraphs.isEmpty else { return }

        let allQuoted = paragraphs.allSatisfy { block(at: $0, in: storage).quoteDepth > 0 }
        let group = uniqueGroup(in: storage)
        for paragraph in paragraphs {
            var target = block(at: paragraph, in: storage)
            if allQuoted {
                target.quoteDepth = 0
                target.quoteGroup = -1
            } else if target.quoteDepth == 0 {
                target.quoteDepth = 1
                target.quoteGroup = group
            }
            restamp(paragraph, to: target, in: textView)
        }
    }

    /// Code block: the selected paragraphs become lines of ONE fenced
    /// block (shared group — the serializer merges same-group codeBlock
    /// paragraphs into a single fence); a fully-code selection reverts to
    /// paragraphs.
    func toggleCodeBlock() {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphs = selectedParagraphs()
        guard !paragraphs.isEmpty else { return }

        let allCode = paragraphs.allSatisfy {
            if case .codeBlock = block(at: $0, in: storage).kind { return true }
            return false
        }
        let group = uniqueGroup(in: storage)
        for paragraph in paragraphs {
            var target = block(at: paragraph, in: storage)
            if allCode {
                target.kind = .paragraph
                target.group = -1
            } else {
                target.kind = .codeBlock(language: "")
                target.group = group
            }
            restamp(paragraph, to: target, in: textView)
        }
    }

    /// ⌘K: add a link on the selection, or edit/remove the link under the
    /// cursor (D9: prefilled text + URL for existing links). Empty selection
    /// with no existing link inserts the URL text.
    func editLink() {
        guard let textView, let storage = textView.textStorage else { return }
        var selection = textView.selectedRange()
        var existingURL = ""
        var existingText = selection.length > 0
            ? (storage.string as NSString).substring(with: selection) : ""

        // Expand to the full run of an existing link under the cursor.
        if storage.length > 0 {
            let probe = min(selection.location, storage.length - 1)
            var effective = NSRange(location: 0, length: 0)
            if let dest = storage.attribute(.mdLink, at: probe,
                                            longestEffectiveRange: &effective,
                                            in: NSRange(location: 0, length: storage.length)) as? String {
                existingURL = dest
                selection = effective
                existingText = (storage.string as NSString).substring(with: effective)
            }
        }

        switch runLinkEditPrompt(existingText: existingText, existingURL: existingURL) {
        case .apply(let display, let url):
            let linkText = display.isEmpty ? url : display
            guard textView.shouldChangeText(in: selection, replacementString: linkText)
            else { return }
            isMutating = true
            var attrs = selection.length > 0
                ? storage.attributes(at: selection.location, effectiveRange: nil)
                : textView.typingAttributes
            attrs[.mdLink] = url
            // Presentation font for links (underline applied by presentation pass).
            storage.replaceCharacters(in: selection,
                                      with: NSAttributedString(string: linkText, attributes: attrs))
            isMutating = false
            textView.didChangeText()
            textView.setSelectedRange(
                NSRange(location: selection.location + (linkText as NSString).length, length: 0))
            afterMutation()
        case .remove:
            guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
            isMutating = true
            storage.removeAttribute(.mdLink, range: selection)
            isMutating = false
            textView.didChangeText()
            afterMutation()
        case .cancel:
            break
        }
    }

    func toggleTaskDone(at paragraph: NSRange) {
        guard let textView, let storage = textView.textStorage else { return }
        var target = block(at: paragraph, in: storage)
        guard case .taskItem(let depth, let done) = target.kind else { return }
        target.kind = .taskItem(depth: depth, done: !done)
        restamp(paragraph, to: target, in: textView)
    }

    func toggleBuiltInPluginTask(at paragraph: NSRange) {
        guard let textView, let storage = textView.textStorage else { return }
        var target = block(at: paragraph, in: storage)
        guard case .builtInPluginTaskItem(let depth, let token) = target.kind,
              token.canCycle else { return }
        target.kind = .builtInPluginTaskItem(depth: depth, token: token.next)
        restamp(paragraph, to: target, in: textView)
    }

    func cycleBuiltInPluginInlineToken(in range: NSRange) {
        guard let textView, let storage = textView.textStorage,
              range.length > 0, NSMaxRange(range) <= storage.length,
              let payload = storage.attribute(.mdBuiltInPluginToken,
                                              at: range.location,
                                              effectiveRange: nil)
                as? BuiltInPluginTokenPayload,
              payload.canCycle else { return }
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
            ?? visualStyle.font(for: [], blockKind: .paragraph)
        let color = attrs[.foregroundColor] as? NSColor
            ?? textView.theme.textColor
        let replacement = builtInPluginTokenAttributedString(
            payload.next, font: font, textColor: color, attributes: attrs)
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        isMutating = true
        storage.replaceCharacters(in: range, with: replacement)
        isMutating = false
        textView.didChangeText()
        afterMutation()
    }

    /// Cmd+click on a wiki-link: resolve its target against the workspace
    /// and open the file (relative to this document's folder), jumping to
    /// the heading when present.
    func openWikiLink(_ payload: MDWikiLinkPayload) {
        navigateToWikiLink(target: payload.target, heading: payload.heading,
                           from: parent.fileURL)
    }

    /// Cmd+click on a regular `[text](destination)` link: scheme URLs go to
    /// the system, local paths resolve vault-absolute / file-relative.
    func openLink(destination: String) {
        openMarkdownLink(destination: destination, from: parent.fileURL)
    }

}
