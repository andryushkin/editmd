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

    /// Which pane the active URL routes to. Answering costs a disk check
    /// (`AppState.isFolder`) and `body` asks four times over — inspector
    /// availability, the sidebar's active-branch mark, the activity bar and the
    /// pane itself — so it is resolved once per `body` and read from there.
    private struct CenterBranch {
        /// The markdown editor, which carries its own status bar with the same
        /// activity chip.
        var isEditor = false
        /// The folder card — it hosts its own right inspector (whole-subtree
        /// analytics), so the toggle must be enabled.
        var isFolder = false
        /// The inspector toggle has a pane to show on the editor and folder branches.
        var inspectorAvailable: Bool { isEditor || isFolder }
    }

    private var centerBranch: CenterBranch {
        if appState.isWelcome { return CenterBranch() }
        guard let url = appState.currentURL else { return CenterBranch(isEditor: true) }
        if AppState.isFolder(url) { return CenterBranch(isFolder: true) }
        return CenterBranch(isEditor: !isPDFFile(url) && !isImageFile(url))
    }

    var body: some View {
        let branch = centerBranch
        // Sidebar lives in `MainChrome` (NOT `.id`-swapped per file); only the
        // CENTER is `.id`-recreated on navigation, so the sidebar's scroll
        // offset, selection and filter survive file switches.
        MainChrome(activeURL: appState.currentURL,
                   activeIsFolder: branch.isFolder,
                   inspectorAvailable: branch.inspectorAvailable) {
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
                    } else if let url = appState.currentURL, branch.isFolder {
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
                if !branch.isEditor {
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

/// Stable left chrome for the MAIN window: `content` is `.id`-swapped per
/// file, but the sidebar lives here so it survives file switches. Owns the
/// sidebar show/hide + width, divider, toolbar toggle and `sidebarVisible`
/// focused value — once per window, not per center branch. Lite windows
/// never mount this.
private struct MainChrome<Content: View>: View {
    /// The file/folder currently on screen — highlights the active row.
    let activeURL: URL?
    /// Whether `activeURL` is the folder card rather than a document: the
    /// sidebar accents the folder that holds the open file, and an open folder
    /// holds itself, not its parent. Read here, where the branch is already
    /// resolved, so no row has to stat the disk.
    let activeIsFolder: Bool
    /// True when the center pane has a right inspector to show — the editor and
    /// folder branches. Keeps the trailing button set constant while disabling
    /// the toggle on the welcome / PDF / image panes.
    let inspectorAvailable: Bool
    @ViewBuilder var content: Content

    @ObservedObject private var workspace = WorkspaceModel.shared
    @ObservedObject private var history = DocumentHistory.shared
    @ObservedObject private var editorSettings = EditorSettings.shared
    @AppStorage("sidebarVisible") private var sidebarVisible = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 220.0
    // Shared with the editor's own `@AppStorage("inspectorVisible")` — the
    // toggle lives here (all branches) but the pane renders in ContentView.
    @AppStorage("inspectorVisible") private var inspectorVisible = false

    /// Same rule as the inspector: the pane may not be dragged narrower than
    /// its own navigator strip, or the trailing tabs get clipped by the edge.
    private static var widthRange: ClosedRange<Double> {
        sidePaneWidthRange(floor: WorkspaceSidebar.minimumPaneWidth)
    }
    private var appearanceIsDark: Bool { editorSettings.general.appearance.isDark }

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
                sidebarWidth: clampPaneWidth(sidebarWidth, to: Self.widthRange),
                inspectorWidth: 0,
                sidebarVisible: sidebarVisible,
                inspectorVisible: false)
            HStack(spacing: 0) {
                if sidebarVisible {
                    WorkspaceSidebar(
                        workspace: workspace,
                        activeURL: activeURL,
                        activeIsFolder: activeIsFolder,
                        onOpen: { openFileFromWorkspaceSidebar($0, currentURL: activeURL) },
                        onOpenFolder: { AppState.shared.openInMainWindow($0) }
                    )
                    .frame(width: panes.sidebar)
                    PaneDivider()
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The strip lives on this container so hit testing reaches it over
            // both panes, and its x is read from the chrome's own left edge —
            // `.global` is screen-relative and would inflate the width on a
            // window not flush to the screen's left.
            .paneGrabStrip(lineX: sidebarVisible ? panes.sidebar : nil) { x in
                sidebarWidth = preferredPaneWidthFromDrag(
                    displayWidth: x, scale: panes.scale, range: Self.widthRange)
            }
            .animation(.easeInOut(duration: 0.15), value: sidebarVisible)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // Toggle (not Button) so macOS draws the active (open) state —
                // matches the inspector toggle; a foregroundStyle tint is often
                // dropped on toolbar SF Symbols.
                Toggle(isOn: $sidebarVisible) {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .toggleStyle(.button)
                .help("Toggle Sidebar (⌃⌘S)")
            }
            // Browser-style Back/Forward over the visited-document history.
            // The engine also drives View ▸ Back/Forward (⌘[ / ⌘]) and the
            // mouse side buttons; this is just the visible, discoverable path.
            ToolbarItem(placement: .navigation) {
                Button { AppState.shared.historyBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Back (⌘[)")
                .disabled(!history.canGoBack)
            }
            ToolbarItem(placement: .navigation) {
                Button { AppState.shared.historyForward() } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .help("Forward (⌘])")
                .disabled(!history.canGoForward)
            }
            // Shared trailing buttons (appearance / agent / inspector) so the
            // main window's toolbar set is identical on every center branch.
            EditorToolbar(
                editorSettings: editorSettings,
                appearanceIsDark: appearanceIsDark,
                inspectorVisible: $inspectorVisible,
                inspectorAvailable: inspectorAvailable
            )
        }
        .focusedSceneValue(\.sidebarVisible, $sidebarVisible)
    }
}

/// Finds the enclosing `NSWindow` after layout and lets the caller configure it
/// (representedURL, title). No SwiftUI API sets representedURL pre-macOS 15.
struct WindowAccessor: NSViewRepresentable {
    /// `@MainActor` because every caller touches window state (title,
    /// representedURL, contentMinSize) — all main-actor AppKit API.
    let configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureAfterLayout(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureAfterLayout(view)
    }

    /// The window only exists after the view joins a hierarchy, so configure on
    /// the next main-queue turn. `DispatchQueue.main` IS the main actor, hence
    /// `assumeIsolated` rather than a `Task` (which would add a hop and let the
    /// window change underneath us).
    private func configureAfterLayout(_ view: NSView) {
        DispatchQueue.main.async { [weak view] in
            MainActor.assumeIsolated {
                if let window = view?.window { configure(window) }
            }
        }
    }
}

/// Real window floor for live resize. SwiftUI `.frame(minWidth:)` on `Window` /
/// `WindowGroup` content is often ignored by AppKit's resize loop; `contentMinSize`
/// is what actually stops the drag. If the window is already below the floor
/// (e.g. restored frame from before the constant rose), grow once so the user
/// is not stuck in an illegal size until they touch the edge.
@MainActor
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
