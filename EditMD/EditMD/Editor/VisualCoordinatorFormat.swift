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
            toggleBulletList: { [weak self] in self?.toggleListKind(
                isTarget: { if case .bulletItem = $0 { return true }; return false },
                makeKind: { .bulletItem(depth: $0) }) },
            toggleNumberedList: { [weak self] in self?.toggleListKind(
                isTarget: { if case .orderedItem = $0 { return true }; return false },
                makeKind: { .orderedItem(depth: $0, number: 1) }) },
            toggleQuote: { [weak self] in self?.toggleQuote() },
            toggleCodeBlock: { [weak self] in self?.toggleCodeBlock() },
            copySelection: { [weak self] in self?.copySelection() },
            insertTable: { [weak self] in self?.insertEmptyTable() },
            tableAddRow: { [weak self] in self?.tableAddRowAtCursor() },
            tableDeleteRow: { [weak self] in self?.tableDeleteRowAtCursor() },
            formulaStub: {
                NSSound.beep()
                let alert = NSAlert()
                alert.messageText = "Формулы"
                alert.informativeText = "Редактирование формул появится позже."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        )
        DispatchQueue.main.async { [parent] in
            parent.onFormatActions(actions)
        }
    }

    private func copySelection() {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { NSSound.beep(); return }
        let text = (textView.string as NSString).substring(with: range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private func insertEmptyTable() {
        guard let textView, let storage = textView.textStorage else { return }
        let md = """
        |   |   |   |
        | --- | --- | --- |
        |   |   |   |
        |   |   |   |

        """
        let rendered = renderMarkdownToAttributed(md, style: visualStyle)
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
        let paragraph = paragraphRange(at: textView.selectedRange().location,
                                       in: storage.string as NSString)
        let current = block(at: paragraph, in: storage)
        if case .tableCell = current.kind {
            if let newRow = appendTableRow(group: current.group) {
                moveCursor(toCell: (newRow, 0), group: current.group)
            }
            return
        }
        // Large-table island: append a body row.
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
        let paragraph = paragraphRange(at: textView.selectedRange().location,
                                       in: storage.string as NSString)
        let current = block(at: paragraph, in: storage)
        if case .tableCell(let row, _, _, _) = current.kind {
            deleteTableRow(row, group: current.group)
            return
        }
        if let island = tableIsland(at: paragraph.location), !island.grid.rows.isEmpty {
            let last = island.grid.rows.count - 1
            if deleteTableIslandRow(paragraphLocation: paragraph.location, atBodyIndex: last) {
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
        toggleListKind(
            isTarget: { if case .taskItem = $0 { return true }; return false },
            makeKind: { .taskItem(depth: $0, done: false) })
    }

    /// Paragraph ranges the selection touches (skipping none); table
    /// cells and raw islands are excluded — block restamps would corrupt
    /// them.
    private func selectedParagraphs() -> [NSRange] {
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
                case .bulletItem(let d), .orderedItem(let d, _), .taskItem(let d, _):
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
    /// cursor. Empty selection with no existing link inserts the URL text.
    func editLink() {
        guard let textView, let storage = textView.textStorage else { return }
        var selection = textView.selectedRange()
        var existingURL = ""

        // Expand to the full run of an existing link under the cursor.
        if storage.length > 0 {
            let probe = min(selection.location, storage.length - 1)
            var effective = NSRange(location: 0, length: 0)
            if let dest = storage.attribute(.mdLink, at: probe,
                                            longestEffectiveRange: &effective,
                                            in: NSRange(location: 0, length: storage.length)) as? String {
                existingURL = dest
                selection = effective
            }
        }

        let alert = NSAlert()
        alert.messageText = existingURL.isEmpty ? "Add Link" : "Edit Link"
        alert.informativeText = "URL:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = existingURL
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if !existingURL.isEmpty { alert.addButton(withTitle: "Remove Link") }

        let response = alert.runModal()
        let url = field.stringValue.trimmingCharacters(in: .whitespaces)

        switch response {
        case .alertFirstButtonReturn where !url.isEmpty:
            if selection.length == 0 {
                // Nothing selected: insert the URL itself as linked text.
                guard textView.shouldChangeText(in: selection, replacementString: url) else { return }
                isMutating = true
                var attrs = textView.typingAttributes
                attrs[.mdLink] = url
                storage.replaceCharacters(in: selection,
                                          with: NSAttributedString(string: url, attributes: attrs))
                isMutating = false
                textView.didChangeText()
                textView.setSelectedRange(
                    NSRange(location: selection.location + (url as NSString).length, length: 0))
            } else {
                guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
                isMutating = true
                storage.addAttribute(.mdLink, value: url, range: selection)
                isMutating = false
                textView.didChangeText()
            }
            afterMutation()
        case .alertThirdButtonReturn:
            guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
            isMutating = true
            storage.removeAttribute(.mdLink, range: selection)
            isMutating = false
            textView.didChangeText()
            afterMutation()
        default:
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

    /// Cmd+click on a wiki-link: resolve its target against the workspace
    /// and open the file (relative to this document's folder).
    func openWikiLink(_ payload: MDWikiLinkPayload) {
        navigateToWikiLink(target: payload.target, from: parent.fileURL)
    }

}
