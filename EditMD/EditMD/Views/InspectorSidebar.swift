import SwiftUI
import AppKit

/// Right inspector panel for document-scope UI (Outline, Info, Links,
/// Backlinks, Properties, later History). Mirrors the left `WorkspaceSidebar`
/// chrome: Xcode-style tab strip, `SidebarChrome` padding, window background.
struct InspectorSidebar: View {
    let fileURL: URL?
    let outlineContent: String
    /// Live git snapshot for the focused file (from ContentView; no new Process).
    let gitSnapshot: GitFileSnapshot
    /// Whether a workspace root is adopted (Backlinks need it).
    let hasWorkspace: Bool
    let onJump: (Int) -> Void
    /// Open a file in the main window (links / backlinks targets).
    let onOpen: (URL) -> Void
    /// Switch to Source and place the caret (Properties «Открыть в Source»).
    var onOpenInSource: ((Int) -> Void)? = nil

    @ObservedObject private var linkIndex = LinkIndex.shared
    @AppStorage("inspectorTab") private var tab = "outline"
    /// Bottom filter field — filters Outline / Links / Backlinks lists.
    @State private var filterText = ""

    private var showsFilterBar: Bool {
        tab != "info" && tab != "properties"
    }

    var body: some View {
        VStack(spacing: 0) {
            navigatorToolbar
                .padding(.horizontal, SidebarChrome.barPaddingH)
                .padding(.top, SidebarChrome.barPaddingTop)
                .padding(.bottom, SidebarChrome.barPaddingBottom)

            Group {
                switch tab {
                case "info":
                    FileInfoPanel(
                        fileURL: fileURL,
                        content: outlineContent,
                        gitSnapshot: gitSnapshot,
                        linkIndex: linkIndex
                    )
                case "properties":
                    PropertiesPanel(
                        content: outlineContent,
                        onOpenInSource: onOpenInSource
                    )
                case "links":
                    OutgoingLinksPanel(
                        fileURL: fileURL,
                        content: outlineContent,
                        filter: filterText,
                        linkIndex: linkIndex,
                        onOpen: onOpen,
                        onJump: onJump
                    )
                case "backlinks":
                    BacklinksPanel(
                        fileURL: fileURL,
                        filter: filterText,
                        hasWorkspace: hasWorkspace,
                        linkIndex: linkIndex,
                        onOpen: onOpen
                    )
                default:
                    // "outline" and any unknown key fall back to Outline.
                    OutlineSidebar(content: outlineContent, filter: filterText, onJump: onJump)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Filter for list tabs only.
            if showsFilterBar {
                bottomBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { linkIndex.ensureIndex() }
    }

    // MARK: - Navigator toolbar

    private var navigatorToolbar: some View {
        HStack(spacing: 0) {
            navTabButton(id: "outline",
                         systemImage: "list.bullet.indent",
                         help: "Outline")
            navDivider
            navTabButton(id: "properties",
                         systemImage: "list.bullet.rectangle",
                         help: "Свойства — frontmatter")
            navDivider
            navTabButton(id: "links",
                         systemImage: "link",
                         help: "Ссылки — исходящие")
            navDivider
            navTabButton(id: "backlinks",
                         systemImage: "arrow.turn.down.left",
                         help: "Backlinks — входящие")
            navDivider
            navTabButton(id: "info",
                         systemImage: "info.circle",
                         help: "Info")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: SidebarChrome.wellColor))
        )
    }

    private var navDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
    }

    private func navTabButton(id: String, systemImage: String, help: String) -> some View {
        let selected = tab == id
        return Button {
            tab = id
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: SidebarChrome.iconButtonWidth,
                       height: SidebarChrome.iconButtonHeight)
                .background(
                    Circle()
                        .fill(selected ? Color.accentColor : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .editMDHelp(help)
    }

    // MARK: - Bottom bar (Filter only)

    private var bottomBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: SidebarChrome.wellColor))
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Outgoing links

/// Live scan of the open buffer + resolution via LinkIndex / WikiLinkResolver.
private struct OutgoingLinksPanel: View {
    let fileURL: URL?
    let content: String
    let filter: String
    @ObservedObject var linkIndex: LinkIndex
    let onOpen: (URL) -> Void
    let onJump: (Int) -> Void

    @State private var liveLinks: [OutgoingLink] = []
    @State private var resolveTask: Task<Void, Never>?

    private var query: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visible: [OutgoingLink] {
        guard !query.isEmpty else { return liveLinks }
        return liveLinks.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.rawTarget.localizedCaseInsensitiveContains(query)
                || $0.context.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            if liveLinks.isEmpty {
                emptyState(linkIndex.isScanning
                           ? "Индекс обновляется…"
                           : "Нет исходящих ссылок")
            } else if visible.isEmpty {
                emptyState("Нет совпадений")
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, link in
                        LinkRowView(link: link, style: .outgoing) {
                            activateOutgoing(link)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { scheduleLiveResolve(delayMs: 0) }
        .onChange(of: content) { _ in scheduleLiveResolve(delayMs: 250) }
        .onChange(of: fileURL) { _ in scheduleLiveResolve(delayMs: 0) }
        // Index republishes `outgoing` / scan flags — re-resolve labels.
        .onChange(of: linkIndex.hasCompletedFullScan) { _ in scheduleLiveResolve(delayMs: 0) }
        .onChange(of: linkIndex.isScanning) { scanning in
            if !scanning { scheduleLiveResolve(delayMs: 0) }
        }
    }

    private func scheduleLiveResolve(delayMs: UInt64) {
        resolveTask?.cancel()
        let text = content
        let url = fileURL
        resolveTask = Task {
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            let scanned = await Task.detached(priority: .userInitiated) {
                scanOutgoingLinks(text: text)
            }.value
            guard !Task.isCancelled else { return }

            // Prefer index-resolved copy for this file when content matches
            // disk-index scan of same targets; always re-resolve live buffer.
            let roots = WorkspaceModel.shared.workspaces.map(\.url)
            let vault: URL? = {
                guard let url else { return roots.first }
                return roots.first {
                    let p = url.path
                    let r = $0.path
                    return p == r || p.hasPrefix(r + "/")
                } ?? nearestVaultRoot(startingAt: url.deletingLastPathComponent())
            }()
            if !roots.isEmpty {
                await WikiLinkResolver.shared.setRoots(roots)
            } else if let dir = url?.deletingLastPathComponent() {
                await WikiLinkResolver.shared.setRoots([dir])
            }

            var resolved: [OutgoingLink] = []
            for link in scanned {
                let wikiHits: [URL]
                if link.kind == .wiki
                    || (link.kind == .image && !link.rawTarget.contains("/")) {
                    wikiHits = await WikiLinkResolver.shared.resolve(link.rawTarget)
                } else {
                    let local = url.flatMap {
                        resolveLocalLinkDestination(
                            link.rawTarget,
                            fileDir: $0.deletingLastPathComponent(),
                            vaultRoot: vault)
                    }
                    wikiHits = local == nil
                        ? await WikiLinkResolver.shared.resolve(link.rawTarget)
                        : []
                }
                if let url {
                    resolved.append(LinkIndex.resolveLink(
                        link, from: url, vaultRoot: vault, wikiMatches: wikiHits))
                } else {
                    var copy = link
                    if let only = wikiHits.first, wikiHits.count == 1 {
                        copy.resolved = only
                        copy.candidates = wikiHits
                    } else if wikiHits.count > 1 {
                        copy.candidates = wikiHits
                    }
                    resolved.append(copy)
                }
            }
            guard !Task.isCancelled else { return }
            liveLinks = resolved
        }
    }

    private func activateOutgoing(_ link: OutgoingLink) {
        if link.candidates.count > 1, link.resolved == nil {
            // Ambiguous — open first candidate (row expands candidates below).
            if let first = link.candidates.first { onOpen(first) }
            return
        }
        if let target = link.resolved {
            onOpen(target)
            return
        }
        NSSound.beep()
    }
}

// MARK: - Backlinks

private struct BacklinksPanel: View {
    let fileURL: URL?
    let filter: String
    let hasWorkspace: Bool
    @ObservedObject var linkIndex: LinkIndex
    let onOpen: (URL) -> Void

    private var query: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var edges: [BacklinkEdge] {
        linkIndex.backlinkEdges(for: fileURL)
    }

    private var visible: [BacklinkEdge] {
        guard !query.isEmpty else { return edges }
        return edges.filter {
            $0.source.lastPathComponent.localizedCaseInsensitiveContains(query)
                || $0.link.label.localizedCaseInsensitiveContains(query)
                || $0.link.context.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            if !hasWorkspace {
                emptyState("Нужен workspace")
            } else if linkIndex.isScanning && edges.isEmpty {
                emptyState("Индекс обновляется…")
            } else if edges.isEmpty {
                emptyState(linkIndex.hasCompletedFullScan
                           ? "Нет входящих ссылок"
                           : "Индекс обновляется…")
            } else if visible.isEmpty {
                emptyState("Нет совпадений")
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, edge in
                        LinkRowView(link: edge.link, style: .backlink(source: edge.source)) {
                            // Open source and jump to the link offset.
                            AppState.shared.requestControlJump(
                                url: edge.source, offset: edge.link.utf16Offset)
                            onOpen(edge.source)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { linkIndex.ensureIndex() }
    }
}

// MARK: - Shared row

private enum LinkRowStyle {
    case outgoing
    case backlink(source: URL)
}

private struct LinkRowView: View {
    let link: OutgoingLink
    let style: LinkRowStyle
    let action: () -> Void

    @State private var hovering = false
    @State private var expanded = false

    private var isMissing: Bool {
        link.resolved == nil && link.candidates.isEmpty
    }
    private var isAmbiguous: Bool {
        link.candidates.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(titleText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isMissing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        if isMissing {
                            Text("не найдена")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        } else if isAmbiguous {
                            Text("неоднозначна")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(subtitleText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !link.context.isEmpty {
                        Text(link.context)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if isAmbiguous {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "Скрыть варианты" : "\(link.candidates.count) варианта…")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                if expanded {
                    ForEach(link.candidates, id: \.path) { cand in
                        Button {
                            AppState.shared.openInMainWindow(cand)
                        } label: {
                            Text((cand.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 12)
                    }
                }
            }
        }
    }

    private var titleText: String {
        switch style {
        case .outgoing:
            return link.label.isEmpty ? link.rawTarget : link.label
        case .backlink(let source):
            return source.lastPathComponent
        }
    }

    private var subtitleText: String {
        switch style {
        case .outgoing:
            let target = link.resolved?.lastPathComponent ?? link.rawTarget
            return "\(target):\(link.line)"
        case .backlink(let source):
            let path = (source.path as NSString).abbreviatingWithTildeInPath
            return "\(path):\(link.line)"
        }
    }
}

private func emptyState(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
}

// MARK: - Info panel

/// Document facts: path/size/mtime (disk, cached), buffer stats (debounced),
/// git status (reused snapshot), link counts from LinkIndex / live scan.
private struct FileInfoPanel: View {
    let fileURL: URL?
    let content: String
    let gitSnapshot: GitFileSnapshot
    @ObservedObject var linkIndex: LinkIndex

    @State private var stats: FileInfoStats = computeFileInfoStats(text: "")
    @State private var diskInfo: FileDiskInfo = .empty
    @State private var refreshTask: Task<Void, Never>?
    @State private var diskCacheKey: String = ""
    @State private var expectedDiskPath: String?
    @State private var liveOutgoingCount = 0

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fileSection
                documentSection
                gitSection
                linksSection
            }
            .padding(.horizontal, 12)
            .padding(.top, SidebarChrome.firstContentTop)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            scheduleRefresh(delayMs: 0)
            linkIndex.ensureIndex()
        }
        .onChange(of: content) { _ in
            scheduleRefresh(delayMs: 250)
        }
        .onChange(of: fileURL) { _ in
            diskInfo = .empty
            diskCacheKey = ""
            scheduleRefresh(delayMs: 0)
        }
    }

    // MARK: Sections

    @ViewBuilder private var fileSection: some View {
        sectionHeader("ФАЙЛ")
        if let url = fileURL {
            infoRow(label: "Имя", value: url.lastPathComponent)
            infoRow(label: "Путь", value: displayPath(for: url))
            Button {
                copyPath(url)
            } label: {
                Label("Скопировать путь", systemImage: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .editMDHelp(url.path)

            if let size = diskInfo.byteSize {
                infoRow(label: "Размер", value: formatByteSize(size))
            } else {
                infoRow(label: "Размер", value: "—")
            }
            if let mtime = diskInfo.modificationDate {
                infoRow(label: "Изменён", value: Self.dateFormatter.string(from: mtime))
            } else {
                infoRow(label: "Изменён", value: "—")
            }
        } else {
            Text("Нет открытого файла")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var documentSection: some View {
        sectionHeader("ДОКУМЕНТ")
        infoRow(label: "Слова", value: "\(stats.words)")
        infoRow(label: "Символы", value: "\(stats.chars)")
        infoRow(label: "Строки", value: "\(stats.lines)")
        infoRow(label: "Заголовки", value: "\(stats.headings)")
        infoRow(label: "Концы строк", value: lineEndingCaption(stats.lineEndings))
        infoRow(label: "Newline в конце",
                value: stats.hasTrailingNewline ? "да" : "нет")
    }

    @ViewBuilder private var gitSection: some View {
        sectionHeader("GIT")
        if gitSnapshot.inRepo {
            let status = gitSnapshot.statusCaption.isEmpty
                ? "clean" : gitSnapshot.statusCaption
            infoRow(label: "Статус", value: status)
            if let branch = gitSnapshot.branch {
                infoRow(label: "Ветка", value: branch)
            }
        } else {
            infoRow(label: "Статус", value: "не в репозитории")
        }
    }

    @ViewBuilder private var linksSection: some View {
        sectionHeader("СВЯЗИ")
        let backCount = linkIndex.backlinkEdges(for: fileURL).count
        let backLabel: String = {
            if !linkIndex.hasCompletedFullScan, linkIndex.isScanning {
                return "…"
            }
            return "\(backCount)"
        }()
        Text("Ссылки: \(liveOutgoingCount)  ·  Backlinks: \(backLabel)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    // MARK: - Chrome helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Path / disk / stats

    /// Parent folder as `~/…/` (tilde + trailing slash). File name is the
    /// separate «Имя» row — path is location, not basename.
    private func displayPath(for url: URL) -> String {
        let dir = url.standardizedFileURL.deletingLastPathComponent()
        var path = (dir.path as NSString).abbreviatingWithTildeInPath
        if path != "/", !path.hasSuffix("/") {
            path += "/"
        }
        return path
    }

    private func copyPath(_ url: URL) {
        copyPathToPasteboard(url)
    }

    /// Debounced refresh of buffer stats, live link count, and disk attributes.
    private func scheduleRefresh(delayMs: UInt64) {
        refreshTask?.cancel()
        let text = content
        let url = fileURL?.standardizedFileURL
        let path = url?.path
        expectedDiskPath = path
        if path == nil {
            diskInfo = .empty
            diskCacheKey = ""
        }
        refreshTask = Task {
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }

            let nextStats = await Task.detached(priority: .userInitiated) {
                computeFileInfoStats(text: text)
            }.value
            guard !Task.isCancelled else { return }
            stats = nextStats

            let linkCount = await Task.detached(priority: .userInitiated) {
                scanOutgoingLinks(text: text).count
            }.value
            guard !Task.isCancelled else { return }
            liveOutgoingCount = linkCount

            guard let url, let path else { return }
            let loaded = await Task.detached(priority: .utility) {
                loadFileDiskInfo(for: url)
            }.value
            guard !Task.isCancelled else { return }
            guard expectedDiskPath == path else { return }
            let key = "\(path)|\(loaded.modificationDate?.timeIntervalSince1970 ?? 0)|\(loaded.byteSize ?? -1)"
            if key == diskCacheKey { return }
            diskCacheKey = key
            diskInfo = loaded
        }
    }
}
