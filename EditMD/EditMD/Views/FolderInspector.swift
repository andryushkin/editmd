import SwiftUI
import AppKit

// MARK: - Aggregate scan (off-main)

/// A single file surfaced in the folder inspector (largest / recent lists).
struct FolderFileRef: Equatable, Sendable, Identifiable {
    var url: URL
    var byteSize: Int64
    var modified: Date?
    var id: String { url.path }
}

/// Whole-subtree aggregates for the folder inspector. Pure data — computed by
/// `scanFolderAggregates` off the main actor and cached per (path, contentEpoch).
/// Complements `FolderTreeStats` (which counts files/folders for the card grid)
/// with content-derived numbers the grid has no room for.
struct FolderAggregates: Equatable, Sendable {
    var markdownFiles: Int
    var imageFiles: Int
    var pdfFiles: Int
    var words: Int
    var characters: Int
    var tasksDone: Int
    var tasksTotal: Int
    var totalBytes: Int64
    var largest: [FolderFileRef]
    var recent: [FolderFileRef]
    /// True when the content read hit its byte budget — words / tasks are a
    /// lower bound, not exact (pathologically large vaults).
    var contentPartial: Bool

    static let empty = FolderAggregates(
        markdownFiles: 0, imageFiles: 0, pdfFiles: 0,
        words: 0, characters: 0, tasksDone: 0, tasksTotal: 0,
        totalBytes: 0, largest: [], recent: [], contentPartial: false)
}

/// Reads every displayable file under `root`, once. Size / mtime come from
/// `resourceValues` (cheap); words / tasks require reading markdown content, so
/// that part is bounded by a byte budget to stay bounded on huge vaults.
/// Synchronous — call off the main actor. Honors `Task.isCancelled`.
/// `onProgress` reports the running count of displayable files seen so far,
/// throttled to roughly every 128 files, so the UI can show a live "N files"
/// counter on large trees instead of an opaque spinner. Called on the scanning
/// thread — the closure must hop to the main actor itself.
func scanFolderAggregates(at root: URL,
                          contentByteBudget: Int64 = 64 * 1024 * 1024,
                          maxFileBytes: Int64 = 4 * 1024 * 1024,
                          fileManager: FileManager = .default,
                          onProgress: (@Sendable (Int) -> Void)? = nil) -> FolderAggregates {
    let markdownExt: Set<String> = ["md", "markdown", "textbundle"]
    let imageExt = supportedImageFileExtensions
    let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
    ]

    var agg = FolderAggregates.empty
    var readBytes: Int64 = 0
    var seen = 0
    // Collect every displayable file (size + mtime only); the top-5 largest /
    // recent are picked with a single sort after the walk.
    var files: [FolderFileRef] = []

    func walk(_ dir: URL) {
        if Task.isCancelled { return }
        let items = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []
        for url in items {
            if Task.isCancelled { return }
            let vals = try? url.resourceValues(forKeys: keys)
            let isDir = vals?.isDirectory ?? false
            let isPackage = vals?.isPackage ?? false
            if isDir && !isPackage {
                walk(url)
                continue
            }
            let ext = url.pathExtension.lowercased()
            let size = Int64(vals?.fileSize ?? 0)
            let isMarkdown = markdownExt.contains(ext)
            let isImage = imageExt.contains(ext)
            let isPDF = ext == "pdf"
            guard isMarkdown || isImage || isPDF else { continue }

            agg.totalBytes += size
            files.append(FolderFileRef(url: url, byteSize: size,
                                       modified: vals?.contentModificationDate))
            if isImage { agg.imageFiles += 1 }
            if isPDF { agg.pdfFiles += 1 }
            if isMarkdown { agg.markdownFiles += 1 }
            seen += 1
            if seen & 0x7F == 0 { onProgress?(seen) }

            // Content read: plain markdown only (not textbundle packages). Skip
            // when the total budget is spent OR this one file is oversized —
            // reading it would blow the budget on a single load (link indexing
            // caps individual files the same way). Either skip marks the counts
            // as a lower bound.
            guard ext == "md" || ext == "markdown" else { continue }
            guard readBytes < contentByteBudget, size <= maxFileBytes else {
                agg.contentPartial = true
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            readBytes += size
            let (words, chars) = wordAndCharCount(in: text)
            agg.words += words
            agg.characters += chars
            let (done, total) = countMarkdownTasks(in: text)
            agg.tasksDone += done
            agg.tasksTotal += total
        }
    }
    walk(root.standardizedFileURL)
    if Task.isCancelled { return .empty }

    agg.largest = Array(files.sorted { $0.byteSize > $1.byteSize }.prefix(5))
    agg.recent = Array(files
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        .prefix(5))
    return agg
}

/// Counts GFM task-list checkboxes: `- [ ]` (open) and `- [x]` (done). A line is
/// a task item when, after leading whitespace, it starts with a list bullet and
/// a `[ ]` / `[x]` marker. Returns (done, total).
func countMarkdownTasks(in text: String) -> (done: Int, total: Int) {
    var done = 0
    var total = 0
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = Substring(rawLine)
        while let first = line.first, first == " " || first == "\t" {
            line = line.dropFirst()
        }
        guard let bullet = line.first, bullet == "-" || bullet == "*" || bullet == "+" else {
            continue
        }
        line = line.dropFirst()
        guard let space = line.first, space == " " || space == "\t" else { continue }
        while let first = line.first, first == " " || first == "\t" {
            line = line.dropFirst()
        }
        // Expect `[ ]` or `[x]`.
        guard line.first == "[" else { continue }
        let afterBracket = line.dropFirst()
        guard let marker = afterBracket.first,
              afterBracket.dropFirst().first == "]" else { continue }
        switch marker {
        case " ":
            total += 1
        case "x", "X":
            total += 1
            done += 1
        default:
            continue
        }
    }
    return (done, total)
}

/// Path → (contentEpoch, aggregates). Mirrors `FolderStatsCache`: invalidated
/// when `WorkspaceModel.contentEpoch` bumps; lookups require an epoch match.
@MainActor
enum FolderAggregatesCache {
    private static var store: [String: (epoch: Int, agg: FolderAggregates)] = [:]

    static func lookup(path: String, epoch: Int) -> FolderAggregates? {
        guard let entry = store[path], entry.epoch == epoch else { return nil }
        return entry.agg
    }

    static func store(path: String, epoch: Int, agg: FolderAggregates) {
        store[path] = (epoch, agg)
    }
}

// MARK: - Link-graph aggregates for the subtree

/// Outgoing / backlink / orphan counts scoped to the folder subtree. Derived
/// from a `LinkIndex` snapshot off the main actor (filtering the whole map on
/// every `body` render would be wasteful on large vaults).
struct FolderGraphStats: Equatable, Sendable {
    var outgoing: Int
    var backlinks: Int
    /// Markdown files in the subtree with zero incoming links.
    var orphans: Int

    static let empty = FolderGraphStats(outgoing: 0, backlinks: 0, orphans: 0)
}

// MARK: - Panel

/// Right-inspector content when the center pane is a folder: whole-subtree
/// analytics that don't fit the folder card's file grid. Sections are
/// independent `@ViewBuilder`s — drop one by deleting its call in `body`.
struct FolderInspectorPanel: View {
    let folderURL: URL

    @ObservedObject private var workspace = WorkspaceModel.shared
    @ObservedObject private var linkIndex = LinkIndex.shared

    @State private var agg: FolderAggregates = .empty
    @State private var aggLoading = true
    /// Live count of files the running scan has seen — drives the loading state.
    @State private var scanProgress = 0
    @State private var graph: FolderGraphStats = .empty
    @State private var scanTask: Task<Void, Never>?
    @State private var graphTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            title
            if aggLoading {
                loadingState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        overviewSection
                        tasksSection
                        graphSection
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, SidebarChrome.firstContentTop)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            linkIndex.ensureIndex()
            reload()
        }
        .onChange(of: folderURL) { _ in
            // New folder: clear both panes so nothing from the old one lingers
            // under the spinner while the fresh scan / reduction runs.
            agg = .empty
            graph = .empty
            reload()
        }
        .onChange(of: workspace.contentEpoch) { _ in reload() }
        // Index republishes backlinks after a scan — recompute folder totals.
        .onChange(of: linkIndex.hasCompletedFullScan) { _ in recomputeGraph() }
        .onChange(of: linkIndex.isScanning) { scanning in
            if !scanning { recomputeGraph() }
        }
        .onDisappear {
            scanTask?.cancel()
            graphTask?.cancel()
        }
    }

    // MARK: Chrome

    private var title: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(workspace.workspaceRoot(at: folderURL)?.name ?? folderURL.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, SidebarChrome.barPaddingTop)
        .padding(.bottom, SidebarChrome.barPaddingBottom)
    }

    /// Shown while the first content walk runs. On a big tree the walk is not
    /// instant, so surface a live file counter instead of a bare spinner —
    /// makes it obvious work is happening and roughly how much.
    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Analyzing folder…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(scanProgress > 0
                 ? String(localized: "\(scanProgress) files scanned")
                 : String(localized: "Reading the tree…"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: scanProgress)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

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
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fileRow(_ ref: FolderFileRef, trailing: String) -> some View {
        Button {
            AppState.shared.openInMainWindow(ref.url)
        } label: {
            HStack(spacing: 6) {
                Text(ref.url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(trailing)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Sections

    /// Reading time at ~200 wpm, humanized.
    private var readingTime: String {
        let minutes = Int((Double(agg.words) / 200.0).rounded(.up))
        if agg.words == 0 { return "—" }
        if minutes < 1 { return String(localized: "< 1 min") }
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(m) min")
    }

    @ViewBuilder private var overviewSection: some View {
        sectionHeader(String(localized: "OVERVIEW"))
        infoRow(label: String(localized: "Markdown"), value: "\(agg.markdownFiles)")
        if agg.imageFiles > 0 {
            infoRow(label: String(localized: "Images"), value: "\(agg.imageFiles)")
        }
        if agg.pdfFiles > 0 {
            infoRow(label: String(localized: "PDFs"), value: "\(agg.pdfFiles)")
        }
        infoRow(label: String(localized: "Total Size"), value: formatByteSize(agg.totalBytes))
        infoRow(label: String(localized: "Words"),
                value: agg.contentPartial ? "~\(agg.words)" : "\(agg.words)")
        infoRow(label: String(localized: "Reading Time"),
                value: (agg.contentPartial && agg.words > 0) ? "~\(readingTime)" : readingTime)

        if !agg.recent.isEmpty {
            sectionHeader(String(localized: "RECENT"))
            ForEach(agg.recent) { ref in
                fileRow(ref, trailing: ref.modified.map { relativeAge($0) } ?? "—")
            }
        }
        if !agg.largest.isEmpty {
            sectionHeader(String(localized: "LARGEST"))
            ForEach(agg.largest) { ref in
                fileRow(ref, trailing: formatByteSize(ref.byteSize))
            }
        }
    }

    @ViewBuilder private var tasksSection: some View {
        if agg.tasksTotal > 0 {
            sectionHeader(String(localized: "TASKS"))
            let fraction = Double(agg.tasksDone) / Double(agg.tasksTotal)
            // Partial content read → the sample undercounts; mark it approximate
            // rather than implying an exact project total.
            let prefix = agg.contentPartial ? "~" : ""
            Text(prefix + String(localized: "\(agg.tasksDone) / \(agg.tasksTotal) done"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
        }
    }

    @ViewBuilder private var graphSection: some View {
        sectionHeader(String(localized: "LINKS"))
        infoRow(label: String(localized: "Outgoing"), value: "\(graph.outgoing)")
        let backLabel = (!linkIndex.hasCompletedFullScan && linkIndex.isScanning)
            ? "…" : "\(graph.backlinks)"
        infoRow(label: String(localized: "Backlinks"), value: backLabel)
        if linkIndex.hasCompletedFullScan {
            infoRow(label: String(localized: "Orphans"), value: "\(graph.orphans)")
        }
    }

    // MARK: Loading

    private func reload() {
        let path = folderURL.standardizedFileURL.path
        let epoch = workspace.contentEpoch
        recomputeGraph()

        // Fresh (path, epoch) hit: the cache is the source of truth for this
        // epoch (invalidated on New File/Folder), so a full content re-walk would
        // just reproduce it. Show it and stop.
        if let cached = FolderAggregatesCache.lookup(path: path, epoch: epoch) {
            scanTask?.cancel()
            agg = cached
            aggLoading = false
            return
        }
        // Miss: drop any stale numbers so the previous folder's OVERVIEW/TASKS
        // don't sit under the spinner, then walk off-main.
        agg = .empty
        scanProgress = 0
        aggLoading = true

        scanTask?.cancel()
        let root = folderURL.standardizedFileURL
        // `Task.detached` is the cancellation owner: cancelling `scanTask`
        // cancels the walk, so `Task.isCancelled` inside `scanFolderAggregates`
        // actually fires. (A plain `Task {}` here would run the scan on the main
        // actor; a nested detached task would not inherit the cancel.)
        scanTask = Task.detached(priority: .utility) {
            let scanned = scanFolderAggregates(at: root) { count in
                Task { @MainActor in
                    // Ignore progress from a scan the view has moved past.
                    guard path == folderURL.standardizedFileURL.path,
                          epoch == workspace.contentEpoch, aggLoading else { return }
                    scanProgress = count
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard path == folderURL.standardizedFileURL.path,
                      epoch == workspace.contentEpoch else { return }
                FolderAggregatesCache.store(path: path, epoch: epoch, agg: scanned)
                agg = scanned
                aggLoading = false
            }
        }
    }

    /// Folder-scoped link totals from a `LinkIndex` snapshot, computed off-main.
    private func recomputeGraph() {
        let prefix = folderURL.standardizedFileURL.path
        let snapshot = linkIndex.snapshot()
        graphTask?.cancel()
        graphTask = Task.detached(priority: .utility) {
            let stats = folderGraphStats(snapshot: snapshot, folderPathPrefix: prefix)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // A fast folder switch could land another folder's totals here.
                guard prefix == folderURL.standardizedFileURL.path else { return }
                graph = stats
            }
        }
    }

    private func relativeAge(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Pure reducer over a `LinkIndex` snapshot: counts outgoing links, backlinks,
/// and orphan markdown files whose path is inside `folderPathPrefix`.
///
/// Orphan here is deliberately simple — a file with no incoming backlink edge.
/// It is NOT the vault-lint `orphanFile` rule: that excludes home docs
/// (README/index) and self-links, so the two numbers can differ. This is a
/// glanceable folder metric, not the authoritative lint.
func folderGraphStats(snapshot: LinkIndexSnapshot,
                      folderPathPrefix: String) -> FolderGraphStats {
    func inFolder(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return p == folderPathPrefix || p.hasPrefix(folderPathPrefix + "/")
    }
    var outgoing = 0
    var mdInFolder: [URL] = []
    for (url, links) in snapshot.outgoing where inFolder(url) {
        outgoing += links.count
        mdInFolder.append(url.standardizedFileURL)
    }
    var backlinks = 0
    for (url, edges) in snapshot.backlinks where inFolder(url) {
        backlinks += edges.count
    }
    let linkedTargets = Set(snapshot.backlinks.keys.map { $0.standardizedFileURL })
    let orphans = mdInFolder.filter { !linkedTargets.contains($0) }.count
    return FolderGraphStats(outgoing: outgoing, backlinks: backlinks, orphans: orphans)
}
