import AppKit

// MARK: - Catalog (background-friendly)

/// Scan workspace roots for wiki completion candidates (basename + frontmatter
/// title/aliases). Call off the main actor for large vaults.
nonisolated func buildWikiCompletionCatalog(
    roots: [URL],
    maxFrontmatterBytes: Int = 2048
) -> [WikiFileCandidate] {
    let mdExt: Set<String> = ["md", "markdown"]
    let fm = FileManager.default
    var result: [WikiFileCandidate] = []
    let stdRoots = roots.map(\.standardizedFileURL)

    func walk(_ dir: URL) {
        if Task.isCancelled { return }
        let items = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in items {
            if Task.isCancelled { return }
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if (vals?.isDirectory ?? false) && !(vals?.isPackage ?? false) {
                walk(url)
                continue
            }
            guard mdExt.contains(url.pathExtension.lowercased()) else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let data = handle.readData(ofLength: maxFrontmatterBytes)
            let prefix = String(decoding: data, as: UTF8.self)
            let meta = wikiCatalogMeta(fromMarkdownPrefix: prefix)
            let std = url.standardizedFileURL
            result.append(WikiFileCandidate(
                url: std,
                basename: wikiBasename(for: std),
                title: meta.title,
                aliases: meta.aliases,
                relativePath: wikiRelativePath(for: std, roots: stdRoots)
            ))
        }
    }
    for root in stdRoots { walk(root) }
    result.sort {
        $0.basename.localizedCaseInsensitiveCompare($1.basename) == .orderedAscending
    }
    return result
}

// MARK: - Popover controller

/// Shared autocomplete popup for Source and Visual NSTextViews.
@MainActor
final class WikiCompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private weak var textView: NSTextView?
    /// Apply replacement through the host's undoable path.
    private let apply: (NSTextView, NSRange, String) -> Void
    /// Extra gate (Visual: not in code/table/raw). Source always true if fence-free.
    private let allowsCompletion: (NSTextView) -> Bool

    private var popover: NSPopover?
    private var tableView: NSTableView?
    private var picks: [WikiCompletionPick] = []
    private var selectedIndex = 0
    private var session: WikiCompletionSession?

    private var catalog: [WikiFileCandidate] = []
    /// Lowercased/sorted once with the catalog build, then reused per keystroke.
    private var rankCatalog = WikiRankCatalog([])
    private var catalogKey = ""
    private var catalogTask: Task<Void, Never>?
    private var headingCache: [String: (mtime: TimeInterval, headings: [String])] = [:]
    private var refreshTask: Task<Void, Never>?

    init(apply: @escaping (NSTextView, NSRange, String) -> Void,
         allowsCompletion: @escaping (NSTextView) -> Bool = { _ in true }) {
        self.apply = apply
        self.allowsCompletion = allowsCompletion
        super.init()
    }

    func attach(to textView: NSTextView) {
        self.textView = textView
    }

    /// Call after text / selection changes.
    func update(fileURL: URL?) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
            self.rebuild(fileURL: fileURL)
        }
    }

    func dismiss() {
        popover?.close()
        popover = nil
        session = nil
        picks = []
    }

    var isVisible: Bool { popover?.isShown == true }

    /// Intercept navigation keys while the popup is open. Returns true if handled.
    func handleKey(event: NSEvent) -> Bool {
        guard isVisible else { return false }
        switch event.keyCode {
        case 125: // down
            moveSelection(+1); return true
        case 126: // up
            moveSelection(-1); return true
        case 36, 48: // return, tab
            acceptSelection(); return true
        case 53: // escape
            dismiss(); return true
        default:
            return false
        }
    }

    // MARK: - Rebuild

    private func rebuild(fileURL: URL?) {
        guard let tv = textView else { dismiss(); return }
        guard allowsCompletion(tv) else { dismiss(); return }

        let text = tv.string
        let caret = tv.selectedRange().location
        guard let session = wikiCompletionSession(text: text, caretUTF16: caret) else {
            dismiss()
            return
        }
        self.session = session

        ensureCatalog()

        switch session.mode {
        case .file:
            let ranked = rankWikiFileCandidates(
                query: session.query, catalog: rankCatalog)
            picks = ranked.map(wikiFilePick(for:))
            selectedIndex = 0
            showOrUpdate(over: tv, caret: caret)
        case .heading(let fileQuery):
            Task { @MainActor in
                let headings = await self.headings(for: fileQuery, currentURL: fileURL,
                                                   currentText: text)
                guard !Task.isCancelled else { return }
                // Session may have changed while loading.
                guard let live = wikiCompletionSession(text: tv.string,
                                                       caretUTF16: tv.selectedRange().location),
                      case .heading = live.mode else {
                    self.dismiss()
                    return
                }
                self.session = live
                self.picks = rankWikiHeadingCandidates(query: live.query, headings: headings)
                    .map(wikiHeadingPick(for:))
                self.selectedIndex = 0
                self.showOrUpdate(over: tv, caret: tv.selectedRange().location)
            }
        }
    }

    private func ensureCatalog() {
        let roots = WorkspaceModel.shared.workspaces.map(\.url)
        let key = roots.map(\.path).joined(separator: "\u{1F}")
            + "|\(WorkspaceModel.shared.contentEpoch)"
        guard key != catalogKey else { return }
        catalogKey = key
        catalogTask?.cancel()
        let captured = roots
        catalogTask = Task {
            let built = await Task.detached(priority: .utility) {
                let items = buildWikiCompletionCatalog(roots: captured)
                return (items, WikiRankCatalog(items))
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.catalog = built.0
                self.rankCatalog = built.1
                // Refresh open session with new catalog.
                if self.isVisible, let tv = self.textView {
                    self.rebuild(fileURL: nil)
                    _ = tv
                }
            }
        }
    }

    private func headings(for fileQuery: String, currentURL: URL?,
                          currentText: String) async -> [String] {
        let q = fileQuery.trimmingCharacters(in: .whitespaces)
        // Empty file query before # — use current document headings.
        if q.isEmpty {
            return markdownOutline(currentText).map(\.title)
        }
        // Prefer current file when basename matches.
        if let currentURL,
           wikiBasename(for: currentURL).caseInsensitiveCompare(q) == .orderedSame
            || currentURL.deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(q) == .orderedSame {
            return markdownOutline(currentText).map(\.title)
        }
        // Resolve via catalog / WikiLinkResolver.
        var url: URL?
        if let hit = catalog.first(where: {
            $0.basename.caseInsensitiveCompare(q) == .orderedSame
        }) {
            url = hit.url
        } else {
            let roots = WorkspaceModel.shared.workspaces.map(\.url)
            await WikiLinkResolver.shared.setRoots(roots)
            url = await WikiLinkResolver.shared.resolve(q).first
        }
        guard let url else { return [] }
        return loadHeadingsCached(url: url)
    }

    private func loadHeadingsCached(url: URL) -> [String] {
        let path = url.path
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate)?.timeIntervalSince1970 ?? 0
        if let hit = headingCache[path], hit.mtime == mtime {
            return hit.headings
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let heads = markdownOutline(text).map(\.title)
        headingCache[path] = (mtime, heads)
        return heads
    }

    // MARK: - UI

    private func showOrUpdate(over textView: NSTextView, caret: Int) {
        if picks.isEmpty {
            dismiss()
            return
        }
        ensurePopover()
        tableView?.reloadData()
        tableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)

        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let popover else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, max(0, textView.string.utf16.count - 1)))
        var rect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 0), in: container)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        if rect.isEmpty {
            rect = NSRect(x: rect.origin.x, y: rect.origin.y, width: 4, height: 16)
        }
        // Also repositions when already shown: NSPopover tracks the new rect
        // on a re-show with the same content controller (closing/reopening is heavy).
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        // Keep editor first responder so typing continues.
        textView.window?.makeFirstResponder(textView)
    }

    private func ensurePopover() {
        if popover != nil { return }
        let table = NSTableView()
        table.style = .plain
        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.delegate = self
        table.dataSource = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.width = 280
        table.addTableColumn(col)
        table.target = self
        table.doubleAction = #selector(doubleClickRow)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        host.view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            host.view.widthAnchor.constraint(equalToConstant: 300),
            host.view.heightAnchor.constraint(equalToConstant: 180),
        ])

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.contentViewController = host
        popover = pop
        tableView = table
    }

    private func moveSelection(_ delta: Int) {
        guard !picks.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + picks.count) % picks.count
        tableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView?.scrollRowToVisible(selectedIndex)
    }

    private func acceptSelection() {
        guard let tv = textView, let session,
              picks.indices.contains(selectedIndex) else {
            dismiss()
            return
        }
        let pick = picks[selectedIndex]
        let range = session.replaceRange
        dismiss()
        apply(tv, range, pick.replacement)
    }

    @objc private func doubleClickRow() {
        acceptSelection()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { picks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("WikiCompCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingMiddle
                field.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(field)
                c.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    field.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                    field.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        guard picks.indices.contains(row) else { return cell }
        let p = picks[row]
        if let sub = p.displaySubtitle, !sub.isEmpty {
            cell.textField?.stringValue = "\(p.displayTitle)  —  \(sub)"
        } else {
            cell.textField?.stringValue = p.displayTitle
        }
        cell.textField?.font = .systemFont(ofSize: 12)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let row = tableView?.selectedRow, row >= 0 {
            selectedIndex = row
        }
    }
}
