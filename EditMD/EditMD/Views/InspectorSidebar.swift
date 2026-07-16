import SwiftUI
import AppKit

/// Right inspector panel for document-scope UI (Outline, Info, later Links /
/// Backlinks / History / Properties). Mirrors the left `WorkspaceSidebar`
/// chrome: Xcode-style tab strip, `SidebarChrome` padding, window background.
struct InspectorSidebar: View {
    let fileURL: URL?
    let outlineContent: String
    /// Live git snapshot for the focused file (from ContentView; no new Process).
    let gitSnapshot: GitFileSnapshot
    let onJump: (Int) -> Void

    @AppStorage("inspectorTab") private var tab = "outline"
    /// Bottom filter field — filters Outline headings (and future lists).
    @State private var filterText = ""

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
                        gitSnapshot: gitSnapshot
                    )
                default:
                    // "outline" and any unknown key fall back to Outline.
                    OutlineSidebar(content: outlineContent, filter: filterText, onJump: onJump)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Filter only (no + / eye — those are workspace-scope).
            // Hide on Info: nothing list-filterable yet.
            if tab != "info" {
                bottomBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Navigator toolbar

    private var navigatorToolbar: some View {
        HStack(spacing: 0) {
            navTabButton(id: "outline",
                         systemImage: "list.bullet.indent",
                         help: "Outline")
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

// MARK: - Info panel

/// Document facts: path/size/mtime (disk, cached), buffer stats (debounced),
/// git status (reused snapshot), links placeholder for plan 02.
private struct FileInfoPanel: View {
    let fileURL: URL?
    let content: String
    let gitSnapshot: GitFileSnapshot

    @State private var stats: FileInfoStats = computeFileInfoStats(text: "")
    @State private var diskInfo: FileDiskInfo = .empty
    @State private var refreshTask: Task<Void, Never>?
    /// Cache key: path + mtime + size so external saves refresh attributes.
    @State private var diskCacheKey: String = ""
    /// Path this panel currently wants disk stats for. Written on the main
    /// actor when a refresh is scheduled; async completions compare against
    /// this `@State` (not a captured `fileURL` copy — View is a struct).
    @State private var expectedDiskPath: String?

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
        }
        .onChange(of: content) { _ in
            // Buffer stats + opportunistic disk re-probe share one debounce
            // (autosave may have updated mtime/size).
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
        // Placeholder for plan 02 (link index + backlinks).
        Text("Ссылки: —  ·  Backlinks: —")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
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

    /// Debounced refresh of buffer stats and disk attributes together.
    /// `expectedDiskPath` is set on the main actor before any await so a
    /// slow stat for file A cannot overwrite the panel after the user
    /// switched to file B.
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

            // Buffer stats (outline parse can be non-trivial on large docs).
            let nextStats = await Task.detached(priority: .userInitiated) {
                computeFileInfoStats(text: text)
            }.value
            guard !Task.isCancelled else { return }
            stats = nextStats

            // Disk size / mtime — same debounce; skip when path already
            // matched a cached (url, mtime, size) key after load.
            guard let url, let path else { return }
            let loaded = await Task.detached(priority: .utility) {
                loadFileDiskInfo(for: url)
            }.value
            guard !Task.isCancelled else { return }
            // `@State` is live storage — not the captured `fileURL` value.
            guard expectedDiskPath == path else { return }
            let key = "\(path)|\(loaded.modificationDate?.timeIntervalSince1970 ?? 0)|\(loaded.byteSize ?? -1)"
            if key == diskCacheKey { return }
            diskCacheKey = key
            diskInfo = loaded
        }
    }
}
