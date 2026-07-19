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
            // Session dirty-line baseline = content at open.
            LineChangeTracker.shared.noteBaseline(url: url, content: doc.content)
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
        ContentView(
            document: host.document,
            fileURL: host.url,
            allowsSidebar: allowsSidebar,
            isMain: isMain,
            onSave: save,
            onSaveAs: saveAs
        )
            .background(WindowAccessor { window in
                window.representedURL = host.url
                window.title = host.url?.lastPathComponent ?? "Untitled"
            })
            // Every content change marks the document dirty → debounced autosave.
            .onReceive(host.document.objectWillChange) { _ in host.markDirty() }
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
    // Appearance is applied at the window root so EVERY pane — welcome,
    // folder card, PDF viewer, editor — follows Settings ▸ General; applying
    // it only inside the editor left the launch screen on the system theme.
    @ObservedObject private var editorSettings = EditorSettings.shared
    @Environment(\.openWindow) private var openWindow

    /// True when the center pane is the markdown editor (which carries its
    /// own status bar with the same activity chip).
    private var isEditorBranch: Bool {
        if appState.isWelcome { return false }
        guard let url = appState.currentURL else { return true }
        return !isPDFFile(url) && !isImageFile(url) && !AppState.isFolder(url)
    }

    var body: some View {
        // The workspace sidebar lives in `MainChrome`, a stable parent that is
        // NOT `.id`-swapped per file. Only the CENTER (welcome / pdf / folder /
        // editor) is `.id`-recreated on navigation, so the sidebar survives file
        // switches — its scroll offset, selection and filter persist (A1).
        MainChrome(activeURL: appState.currentURL) {
            VStack(spacing: 0) {
                Group {
                    if appState.isWelcome {
                        WelcomeHost()
                            .id("·welcome·")
                    } else if let url = appState.currentURL, isPDFFile(url) {
                        // PDFs bypass DocumentRegistry entirely — read-only PDFKit pane.
                        PDFViewerHost(fileURL: url)
                            .id("pdf:" + url.absoluteString)
                    } else if let url = appState.currentURL, isImageFile(url) {
                        // Images are read-only and never enter the Markdown document path.
                        ImageViewerHost(fileURL: url)
                            .id("image:" + url.absoluteString)
                    } else if let url = appState.currentURL, AppState.isFolder(url) {
                        FolderInfoHost(folderURL: url)
                            .id("folder:" + url.absoluteString)
                    } else {
                        // File URL, or nil + isUntitled → scratch editor.
                        FileEditor(url: appState.currentURL, allowsSidebar: true, isMain: true)
                            .id(appState.currentURL?.absoluteString ?? "·untitled·")
                    }
                }
                // Panes without an editor status bar still surface background
                // workspace work (index scan / vault-lint) — the editor branch
                // shows the same chip inside its own status bar.
                if !isEditorBranch {
                    StandaloneActivityBar()
                }
            }
        }
        .frame(minWidth: mainWindowMinWidth, minHeight: mainWindowMinHeight)
        .preferredColorScheme(editorSettings.general.appearance.colorScheme)
        .longRunningOperationOverlay()
        .background(WindowAccessor { window in
            applyWindowContentMinimum(window,
                                      width: mainWindowMinWidth,
                                      height: mainWindowMinHeight)
            appState.bindMainWindow(window)
        })
        .onAppear { appState.bindOpenWindow(openWindow) }
        // Claude's `openDiff` can target any file, not just the one on screen —
        // the sheet belongs to the window, not to the current document view.
        .claudeDiffApproval()
    }
}

/// Stable left workspace chrome for the MAIN window. The `content` (the center
/// pane) is `.id`-swapped per file, but the sidebar lives here so it survives
/// file switches — no teardown, so its scroll position, multi-selection and
/// filter text persist (A1). Owns the sidebar show/hide + width, the divider,
/// the toolbar toggle and the `sidebarVisible` focused value, so those exist
/// once for the whole window instead of once per center branch. Lite windows
/// have no workspace sidebar and never mount this.
private struct MainChrome<Content: View>: View {
    /// The file/folder currently on screen — highlights the active row.
    let activeURL: URL?
    @ViewBuilder var content: Content

    @ObservedObject private var workspace = WorkspaceModel.shared
    @AppStorage("sidebarVisible") private var sidebarVisible = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 220.0

    private static var widthRange: ClosedRange<Double> { 150.0...400.0 }
    private static var paneSpace: String { "mainChromePanes" }

    var body: some View {
        GeometryReader { geo in
            // Single-side clamp: keep the editor its floor as the window narrows.
            // The inspector (right, in ContentView) clamps in its own scope; with
            // the enforced window minimum the two never overlap. Trade-off vs the
            // old joint clamp: when both panels are near-max in a near-min window
            // the squeeze is not shared 50/50 — the sidebar (clamped first here,
            // against the full width) keeps its width and the inspector absorbs
            // the deficit. No overlap, defaults fit; only the split of an extreme
            // squeeze differs. Kept split to avoid hoisting inspector state up.
            let panes = resolveSidePaneWidths(
                available: geo.size.width,
                sidebarWidth: sidebarWidth,
                inspectorWidth: 0,
                sidebarVisible: sidebarVisible,
                inspectorVisible: false)
            HStack(spacing: 0) {
                if sidebarVisible {
                    WorkspaceSidebar(
                        workspace: workspace,
                        activeURL: activeURL,
                        onOpen: { openFileFromWorkspaceSidebar($0, currentURL: activeURL) },
                        onOpenFolder: { AppState.shared.openInMainWindow($0) }
                    )
                    .frame(width: panes.sidebar)
                    paneDivider(scale: panes.scale)
                        .zIndex(1)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Named space so the divider drag reads x from the chrome's own left
            // edge. `.global` is screen-relative — on a window not flush to the
            // screen's left it would inflate the width toward the max.
            .coordinateSpace(name: Self.paneSpace)
            .animation(.easeInOut(duration: 0.15), value: sidebarVisible)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { sidebarVisible.toggle() } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .help("Toggle Sidebar (⌃⌘S)")
            }
        }
        .focusedSceneValue(\.sidebarVisible, $sidebarVisible)
    }

    /// agterm-style divider: 1px separator + a wider invisible grab strip. The
    /// sidebar starts at x=0 of the chrome's coordinate space, so the cursor x
    /// IS the sidebar's display width — inverted through the clamp scale so a
    /// resize in a clamped window keeps the preferred width.
    private func paneDivider(scale: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.paneSpace))
                            .onChanged { value in
                                sidebarWidth = preferredPaneWidthFromDrag(
                                    displayWidth: value.location.x, scale: scale,
                                    range: Self.widthRange)
                            }
                    )
            }
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

/// Real window floor for live resize. SwiftUI `.frame(minWidth:)` on `Window` /
/// `WindowGroup` content is often ignored by AppKit's resize loop; `contentMinSize`
/// is what actually stops the drag. If the window is already below the floor
/// (e.g. restored frame from before the constant rose), grow once so the user
/// is not stuck in an illegal size until they touch the edge.
func applyWindowContentMinimum(_ window: NSWindow, width: CGFloat, height: CGFloat) {
    let min = NSSize(width: width, height: height)
    if window.contentMinSize != min {
        window.contentMinSize = min
    }
    let content = window.contentLayoutRect.size
    guard content.width + 0.5 < width || content.height + 0.5 < height else { return }
    let dw = max(0, width - content.width)
    let dh = max(0, height - content.height)
    var frame = window.frame
    frame.size.width += dw
    frame.size.height += dh
    // AppKit origin is bottom-left; grow downward so the title bar stays put.
    frame.origin.y -= dh
    window.setFrame(frame, display: true)
}
