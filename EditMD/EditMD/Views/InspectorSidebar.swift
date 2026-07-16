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

    @ObservedObject private var workspace = WorkspaceModel.shared
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
                        gitSnapshot: gitSnapshot,
                        workspace: workspace
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
    @ObservedObject var workspace: WorkspaceModel

    @State private var stats: FileInfoStats = computeFileInfoStats(text: "")
    @State private var diskInfo: FileDiskInfo = .empty
    @State private var statsTask: Task<Void, Never>?
    /// Cache key: path + mtime so external saves refresh size/date.
    @State private var diskCacheKey: String = ""

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
            scheduleStatsRefresh(delayMs: 0)
            refreshDiskInfo()
        }
        .onChange(of: content) { _ in
            scheduleStatsRefresh(delayMs: 250)
            // Autosave may have updated mtime/size — re-probe off-main.
            refreshDiskInfo()
        }
        .onChange(of: fileURL) { _ in
            diskInfo = .empty
            diskCacheKey = ""
            refreshDiskInfo()
            scheduleStatsRefresh(delayMs: 0)
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

    private func displayPath(for url: URL) -> String {
        let std = url.standardizedFileURL
        if let ws = workspace.workspaceOwning(std),
           let rel = workspace.relativePath(of: std, in: ws) {
            return rel
        }
        return (std.path as NSString).abbreviatingWithTildeInPath
    }

    private func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private func scheduleStatsRefresh(delayMs: UInt64) {
        statsTask?.cancel()
        let text = content
        statsTask = Task {
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            // Outline parse can be non-trivial on large docs — off main.
            let next = await Task.detached(priority: .userInitiated) {
                computeFileInfoStats(text: text)
            }.value
            guard !Task.isCancelled else { return }
            stats = next
        }
    }

    private func refreshDiskInfo() {
        guard let url = fileURL else {
            diskInfo = .empty
            diskCacheKey = ""
            return
        }
        let path = url.standardizedFileURL.path
        Task {
            let loaded = await Task.detached(priority: .utility) {
                loadFileDiskInfo(for: url)
            }.value
            guard !Task.isCancelled else { return }
            // Drop stale results if the user switched files mid-load.
            guard fileURL?.standardizedFileURL.path == path else { return }
            let key = "\(path)|\(loaded.modificationDate?.timeIntervalSince1970 ?? 0)|\(loaded.byteSize ?? -1)"
            if key == diskCacheKey { return }
            diskCacheKey = key
            diskInfo = loaded
        }
    }
}
