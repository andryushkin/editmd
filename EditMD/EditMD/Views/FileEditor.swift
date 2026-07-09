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

/// The single main workspace window. Shows whatever `AppState.currentURL` points
/// at — a file (editor) or a directory (folder info card). Changing that reloads
/// the center pane in place (`.id`). Hands the window action to `AppState` on
/// appear so AppKit-side callers can drive windows.
struct MainWindowView: View {
    @ObservedObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let url = appState.currentURL, AppState.isFolder(url) {
                FolderInfoHost(folderURL: url)
                    .id("folder:" + url.absoluteString)
            } else {
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
