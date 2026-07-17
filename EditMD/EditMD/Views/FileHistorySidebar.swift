import SwiftUI
import AppKit

// MARK: - Pure helpers (testable)

/// Diff buffer vs last-known disk when they differ; nil when equal or disk unknown.
func unsavedHistoryDiff(buffer: String, disk: String?) -> LineDiffResult? {
    guard let disk, disk != buffer else { return nil }
    return lineDiff(before: disk, after: buffer)
}

/// Restore preview is only valid while the live buffer still matches the
/// baseline captured when the diff sheet opened.
func canApplyHistoryRestore(previewBaseline: String, currentContent: String) -> Bool {
    previewBaseline == currentContent
}

// MARK: - Panel

/// Right-inspector «История» tab: unsaved buffer, local revisions, git log.
struct FileHistoryPanel: View {
    let fileURL: URL?
    @ObservedObject var document: MarkdownDocument
    /// When set, «Восстановить…» is offered on revision diffs (stage 5).
    var onRestore: ((_ oldContent: String, _ baseline: String) -> Void)? = nil

    @ObservedObject private var gitCache = FileHistoryGitCache.shared
    @State private var localRevisions: [FileRevisionEntry] = []
    @State private var refreshTask: Task<Void, Never>?
    @State private var unsaved: LineDiffResult?
    @State private var sheet: HistoryDiffSheetModel?
    @State private var inRepo = true

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if fileURL == nil {
                    emptyState(String(localized: "No open file"))
                } else {
                    unsavedSection
                    localSection
                    gitSection
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, SidebarChrome.firstContentTop)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { scheduleRefresh(delayMs: 0) }
        .onChange(of: document.content) { _ in scheduleRefresh(delayMs: 250) }
        .onChange(of: fileURL) { _ in
            localRevisions = []
            unsaved = nil
            scheduleRefresh(delayMs: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gitRepositoryDidChange)) { _ in
            gitCache.ensureLoaded(url: fileURL)
        }
        .sheet(item: $sheet) { model in
            HistoryRevisionDiffSheet(
                model: model,
                onClose: { sheet = nil },
                onRestore: onRestore
            )
        }
    }

    // MARK: Sections

    @ViewBuilder private var unsavedSection: some View {
        if let unsaved {
            sectionHeader(String(localized: "UNSAVED"))
            Button {
                openUnsavedDiff()
            } label: {
                historyRow(
                    title: String(localized: "Buffer ↔ disk"),
                    subtitle: "+\(unsaved.added) −\(unsaved.removed)",
                    systemImage: "pencil.circle"
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var localSection: some View {
        sectionHeader(String(localized: "LOCAL REVISIONS"))
        if localRevisions.isEmpty {
            Text("No snapshots yet")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else {
            ForEach(localRevisions) { rev in
                Button {
                    openLocalDiff(rev)
                } label: {
                    historyRow(
                        title: Self.dateFormatter.string(from: rev.savedAt),
                        subtitle: "\(rev.byteSize) B · \(String(rev.contentSHA.prefix(8)))",
                        systemImage: "clock.arrow.circlepath"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var gitSection: some View {
        if !inRepo {
            EmptyView()
        } else {
            sectionHeader("GIT")
            if let entries = gitCache.history(for: fileURL) {
                if entries.isEmpty {
                    Text("No commits for this file")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(entries) { entry in
                        Button {
                            openGitDiff(entry)
                        } label: {
                            historyRow(
                                title: entry.subject.isEmpty ? entry.shortHash : entry.subject,
                                subtitle: "\(entry.shortHash) · \(entry.author) · \(Self.dateFormatter.string(from: entry.date))",
                                systemImage: "arrow.triangle.branch"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if gitCache.isLoading(url: fileURL) {
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    private func historyRow(title: String, subtitle: String,
                            systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }

    // MARK: Refresh

    private func scheduleRefresh(delayMs: UInt64) {
        refreshTask?.cancel()
        let url = fileURL
        let buffer = document.content
        refreshTask = Task {
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            let disk = url.flatMap { DocumentRegistry.shared.knownDiskContent(of: $0) }
            // Full diff + store/git probes stay off the main actor (CLAUDE.md).
            let (unsavedDiff, locals, repo): (LineDiffResult?, [FileRevisionEntry], Bool) =
                await Task.detached(priority: .utility) {
                    let diff = unsavedHistoryDiff(buffer: buffer, disk: disk)
                    guard let url else { return (diff, [], false) }
                    let revisions = FileRevisionStore.shared.revisions(for: url)
                    let inRepo = GitCLI.repositoryRoot(containing: url) != nil
                    return (diff, revisions, inRepo)
                }.value
            guard !Task.isCancelled else { return }
            unsaved = unsavedDiff
            localRevisions = locals
            inRepo = repo
            if repo {
                gitCache.ensureLoaded(url: url)
            }
        }
    }

    // MARK: Open diffs

    private func openUnsavedDiff() {
        guard let url = fileURL,
              let disk = DocumentRegistry.shared.knownDiskContent(of: url),
              let unsaved
        else { return }
        // `unsaved` is the already-computed buffer↔disk diff for this state.
        sheet = HistoryDiffSheetModel(
            id: "unsaved",
            title: String(localized: "Unsaved Changes"),
            fileName: url.lastPathComponent,
            sideLabel: String(localized: "disk → buffer"),
            before: disk,
            after: document.content,
            baselineContent: document.content,
            oldLabel: String(localized: "On disk"),
            canRestore: false,
            stats: unsaved
        )
    }

    private func openLocalDiff(_ rev: FileRevisionEntry) {
        guard let url = fileURL else { return }
        let current = document.content
        Task.detached(priority: .userInitiated) {
            let old = FileRevisionStore.shared.content(for: url, contentSHA: rev.contentSHA) ?? ""
            let stats = lineDiff(before: old, after: current)
            await MainActor.run {
                sheet = HistoryDiffSheetModel(
                    id: rev.id,
                    title: String(localized: "Local revision"),
                    fileName: url.lastPathComponent,
                    sideLabel: String(localized: "revision → now"),
                    before: old,
                    after: current,
                    baselineContent: current,
                    oldLabel: FileHistoryPanel.dateFormatter.string(from: rev.savedAt),
                    canRestore: true,
                    stats: stats
                )
            }
        }
    }

    private func openGitDiff(_ entry: GitFileHistoryEntry) {
        guard let url = fileURL else { return }
        let current = document.content
        Task.detached(priority: .userInitiated) {
            let old = GitCLI.fileContents(of: url, at: entry.hash) ?? ""
            let stats = lineDiff(before: old, after: current)
            await MainActor.run {
                sheet = HistoryDiffSheetModel(
                    id: entry.hash,
                    title: entry.subject.isEmpty ? entry.shortHash : entry.subject,
                    fileName: url.lastPathComponent,
                    sideLabel: String(localized: "\(entry.shortHash) → now"),
                    before: old,
                    after: current,
                    baselineContent: current,
                    oldLabel: entry.shortHash,
                    canRestore: true,
                    stats: stats
                )
            }
        }
    }
}

// MARK: - Diff sheet model

struct HistoryDiffSheetModel: Identifiable, Equatable {
    let id: String
    let title: String
    let fileName: String
    let sideLabel: String
    let before: String
    let after: String
    /// Document content when the sheet opened (stale-check for restore).
    let baselineContent: String
    let oldLabel: String
    let canRestore: Bool
    /// Diff computed ONCE when the sheet opens (off-main for revisions) —
    /// SwiftUI body must not run lineDiff (CLAUDE.md).
    let stats: LineDiffResult
}

// MARK: - Diff sheet (History)

struct HistoryRevisionDiffSheet: View {
    let model: HistoryDiffSheetModel
    let onClose: () -> Void
    var onRestore: ((_ oldContent: String, _ baseline: String) -> Void)? = nil

    @State private var confirmRestore = false

    private var stats: LineDiffResult { model.stats }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DiffTextRepresentable(lines: stats.lines,
                                  before: model.before,
                                  after: model.after)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 1200, idealWidth: 1320, minHeight: 560, idealHeight: 780)
        .alert(String(localized: "Restore this revision?"), isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) {
                onRestore?(model.before, model.baselineContent)
                onClose()
            }
        } message: {
            Text("\(model.oldLabel)\n+\(stats.added) −\(stats.removed) lines relative to the current version.\nUndo with ⌘Z.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(model.fileName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    DiffStatsLabel(added: stats.added, removed: stats.removed,
                                   font: .system(size: 12, design: .monospaced))
                }
            }
            Spacer()
            Text(model.sideLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25),
                            in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Copy Old Version") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.before, forType: .string)
            }
            .controlSize(.small)
            Spacer()
            if model.canRestore, onRestore != nil {
                Button("Restore…") {
                    confirmRestore = true
                }
                .controlSize(.small)
            }
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
    }
}
