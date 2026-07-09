import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Owns the `MarkdownDocument` for one window, resolved from `DocumentRegistry`
/// so several windows on the same file share one model + save path + undo stack.
/// Tied to SwiftUI view identity: `.id(url)` recreates the `DocHost` on file
/// change → acquire new / release old. Released docs stay in the registry's
/// session cache so switching files keeps independent ⌘Z histories.
@MainActor
final class DocHost: ObservableObject {
    let document: MarkdownDocument
    let url: URL?
    /// Whether the document is registry-backed (autosave/shared). Untitled or a
    /// failed load falls back to a standalone scratch document.
    let registered: Bool

    init(url: URL?) {
        if let url, let doc = try? DocumentRegistry.shared.acquire(url) {
            self.url = url
            self.document = doc
            self.registered = true
        } else {
            self.url = nil
            self.document = MarkdownDocument()
            self.registered = false
        }
    }

    func markDirty() {
        if let url, registered { DocumentRegistry.shared.markDirty(url) }
    }

    func saveNow() {
        if let url, registered { try? DocumentRegistry.shared.saveNow(url) }
    }

    deinit {
        // deinit is nonisolated; hop to the main actor to balance acquire.
        // Capture document so we can flush typing coalescing onto its undo stack
        // before parking it in the session cache.
        let doc = document
        let fileURL = url
        let wasRegistered = registered
        Task { @MainActor in
            doc.commitContentEdit()
            if let fileURL, wasRegistered {
                DocumentRegistry.shared.release(fileURL)
            }
        }
    }
}

/// One window's editor: resolves the document, hosts `ContentView`, keeps the
/// window's `representedURL`/title current, and publishes Save/Save As for the
/// manual File menu.
struct FileEditor: View {
    let allowsSidebar: Bool
    let isMain: Bool
    @StateObject private var host: DocHost

    init(url: URL?, allowsSidebar: Bool, isMain: Bool) {
        self.allowsSidebar = allowsSidebar
        self.isMain = isMain
        _host = StateObject(wrappedValue: DocHost(url: url))
    }

    var body: some View {
        ContentView(document: host.document, fileURL: host.url, allowsSidebar: allowsSidebar)
            .background(WindowAccessor { window in
                window.representedURL = host.url
                window.title = host.url?.lastPathComponent ?? "Untitled"
            })
            // Every content change marks the document dirty → debounced autosave.
            .onReceive(host.document.objectWillChange) { _ in host.markDirty() }
            .focusedSceneValue(\.documentActions, DocumentActions(
                save: save, saveAs: saveAs, hasURL: host.url != nil))
    }

    private func save() {
        if host.url != nil { host.saveNow() } else { saveAs() }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.markdown]
        panel.nameFieldStringValue = host.url?.lastPathComponent ?? "Untitled.md"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? writeMarkdownDocument(content: host.document.content,
                                   assets: host.document.assetsFileWrapper,
                                   to: dest.standardizedFileURL)
        // Re-open the now-titled file so it becomes registry-backed.
        if isMain { AppState.shared.openInMainWindow(dest.standardizedFileURL) }
    }
}

/// The single main workspace window. Shows whatever `AppState` points at —
/// welcome home, a file (editor), or a directory (folder info card). Changing
/// that reloads the center pane in place (`.id`). Hands the window action to
/// `AppState` on appear so AppKit-side callers can drive windows.
struct MainWindowView: View {
    @ObservedObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appState.isWelcome {
                WelcomeHost()
                    .id("·welcome·")
            } else if let url = appState.currentURL, AppState.isFolder(url) {
                FolderInfoHost(folderURL: url)
                    .id("folder:" + url.absoluteString)
            } else {
                // File URL, or nil + isUntitled → scratch editor.
                FileEditor(url: appState.currentURL, allowsSidebar: true, isMain: true)
                    .id(appState.currentURL?.absoluteString ?? "·untitled·")
            }
        }
        .onAppear { appState.bindOpenWindow(openWindow) }
    }
}

/// Finds the enclosing `NSWindow` after layout and lets the caller configure it
/// (representedURL, title). No SwiftUI API sets representedURL pre-macOS 15.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
    }
}


// MARK: - Model

enum ExternalChangeKind: Equatable, Sendable {
    /// Clean buffer was auto-reloaded; `before` is the previous in-memory text.
    case applied
    /// Buffer is dirty; `before` = mine, `after` = disk. Not applied yet.
    case conflict
}

struct ExternalChangeNotice: Equatable, Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let before: String
    let after: String
    let kind: ExternalChangeKind
    let added: Int
    let removed: Int

    var fileName: String { url.lastPathComponent }

    var statsLabel: String {
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if removed > 0 { parts.append("−\(removed)") }
        return parts.isEmpty ? "no line changes" : parts.joined(separator: " ")
    }
}

/// Per-URL notices posted by `DocumentRegistry` when the open file changes on disk.
@MainActor
final class ExternalChangeCenter: ObservableObject {
    static let shared = ExternalChangeCenter()

    @Published private(set) var notices: [URL: ExternalChangeNotice] = [:]

    func post(_ notice: ExternalChangeNotice) {
        notices[notice.url.standardizedFileURL] = notice
    }

    func dismiss(_ url: URL) {
        notices.removeValue(forKey: url.standardizedFileURL)
    }

    func notice(for url: URL?) -> ExternalChangeNotice? {
        guard let url else { return nil }
        return notices[url.standardizedFileURL]
    }
}

// MARK: - Banner (all editor modes)

struct ExternalChangeBanner: View {
    let notice: ExternalChangeNotice
    let onShowDiff: () -> Void
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.kind == .conflict
                  ? "exclamationmark.triangle.fill"
                  : "arrow.down.doc.fill")
                .foregroundStyle(notice.kind == .conflict ? Color.orange : Color.accentColor)
                .help(notice.kind == .conflict
                      ? "Local edits conflict with a newer file on disk"
                      : "File was updated on disk and reloaded")

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(notice.statsLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Diff", action: onShowDiff)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("d", modifiers: [.command, .shift])

            if notice.kind == .conflict {
                Button("Keep Mine", action: onSecondary)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Write this buffer to disk, discarding the external version")
                Button("Take Disk", action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Replace the buffer with the file on disk")
            } else {
                Button("Revert", action: onSecondary)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Restore the text from before the external reload")
                Button("OK", action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bannerBackground)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var title: String {
        switch notice.kind {
        case .applied:
            return "Updated from disk — \(notice.fileName)"
        case .conflict:
            return "Conflict with disk — \(notice.fileName)"
        }
    }

    private var bannerBackground: some View {
        (notice.kind == .conflict
            ? Color.orange.opacity(0.12)
            : Color.accentColor.opacity(0.10))
    }
}

// MARK: - Unified diff sheet

struct UnifiedDiffSheet: View {
    let notice: ExternalChangeNotice
    let onClose: () -> Void

    private var result: LineDiffResult {
        lineDiff(before: notice.before, after: notice.after)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            diffBody
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.kind == .conflict ? "Conflict diff" : "External change")
                    .font(.headline)
                Text("\(notice.fileName)  ·  \(notice.statsLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(notice.kind == .conflict ? "mine → disk" : "before → after")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25),
                            in: Capsule())
        }
        .padding(14)
    }

    private var diffBody: some View {
        let lines = result.lines
        let display = lines.count > 8_000 ? Array(lines.prefix(8_000)) : lines
        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(display.enumerated()), id: \.offset) { _, line in
                    DiffLineRow(line: line)
                }
                if lines.count > display.count {
                    Text("… \(lines.count - display.count) more lines omitted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var footer: some View {
        HStack {
            Text("GitHub-style unified diff · red removed · green added")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(gutterOld)
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(gutterNew)
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
            Text(prefix)
                .frame(width: 14, alignment: .center)
                .foregroundStyle(prefixColor)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(rowBackground)
        .textSelection(.enabled)
    }

    private var gutterOld: String {
        line.oldNumber.map(String.init) ?? ""
    }

    private var gutterNew: String {
        line.newNumber.map(String.init) ?? ""
    }

    private var prefix: String {
        switch line.kind {
        case .same: return " "
        case .insert: return "+"
        case .delete: return "−"
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .same: return .secondary
        case .insert: return Color(red: 0.15, green: 0.55, blue: 0.25)
        case .delete: return Color(red: 0.75, green: 0.2, blue: 0.2)
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .same:
            return .clear
        case .insert:
            return Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(red: 0.15, green: 0.35, blue: 0.18, alpha: 0.45)
                    : NSColor(red: 0.85, green: 0.96, blue: 0.88, alpha: 1)
            })
        case .delete:
            return Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(red: 0.4, green: 0.15, blue: 0.15, alpha: 0.45)
                    : NSColor(red: 0.98, green: 0.88, blue: 0.88, alpha: 1)
            })
        }
    }
}
