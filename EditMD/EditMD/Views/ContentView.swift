import SwiftUI

struct ContentView: View {

    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?
    /// Lite (separate) windows pass false to suppress the workspace sidebar.
    var allowsSidebar: Bool = true
    /// Main workspace window (Save As re-opens in place).
    var isMain: Bool = true
    var onSave: () -> Void = {}
    var onSaveAs: () -> Void = {}

    @AppStorage("editorMode") private var storedMode: String = EditorMode.preview.rawValue
    /// Sidebar (document outline) show/hide + width, persisted like the mode.
    @AppStorage("sidebarVisible") private var sidebarVisible = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 220.0
    /// Editor+preview split: on = the edit pane (Source/Visual) plus a live
    /// Preview pane side by side; `splitFraction` is the edit pane's share.
    @AppStorage("splitPreview") private var splitPreview = false
    @AppStorage("splitFraction") private var splitFraction = 0.5
    @ObservedObject private var editorSettings = EditorSettings.shared
    @ObservedObject private var workspace = WorkspaceModel.shared
    @ObservedObject private var externalChanges = ExternalChangeCenter.shared
    @ObservedObject private var lineChanges = LineChangeTracker.shared
    @State private var wordCount = 0
    @State private var charCount = 0
    @State private var formatActions: FormatActions?
    @State private var lintSummary: LintSummary?
    @State private var positionStore = EditorPositionStore()
    /// Shared Notes-style action strip (all three modes). Held in a ref box so
    /// rebinding closures does not trigger SwiftUI view updates.
    @State private var stripActions = EditorStripActions()
    @State private var showExternalDiff = false
    @State private var showGitCommit = false
    @State private var gitSnapshot = GitFileSnapshot.empty
    @State private var gitRefreshTask: Task<Void, Never>?

    private static let sidebarWidthRange = 150.0...400.0
    private static let splitFractionRange = 0.25...0.75

    private var mode: EditorMode { EditorMode(rawValue: storedMode) ?? .preview }

    /// The active theme: the Settings window's preset plus its color
    /// overrides. Single source of truth — the toolbar's Theme menu and the
    /// General settings tab both write `editorSettings.general.themePreset`,
    /// so neither can drift from the other.
    private var theme: EditorTheme { editorSettings.effectiveTheme }

    /// Whether the window currently renders dark — resolves `.system` against
    /// the app's effective appearance so the ☀/🌙 toolbar toggle flips the
    /// right way.
    private var appearanceIsDark: Bool {
        switch editorSettings.general.appearance {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    private var modeBinding: Binding<EditorMode> {
        Binding(
            get: { EditorMode(rawValue: storedMode) ?? .preview },
            set: { setEditorMode($0) }
        )
    }

    /// Split toggle shared by the toolbar button and the View menu: turning
    /// the split ON while in Preview mode switches to Visual — the split's
    /// right pane IS the preview, a preview-next-to-preview is pointless.
    private var splitBinding: Binding<Bool> {
        Binding(
            get: { splitPreview },
            set: { on in
                splitPreview = on
                if on, mode == .preview { setEditorMode(.visual) }
            }
        )
    }

    /// Switch editor mode after flushing any coalesced typing onto the
    /// document undo stack (so ⌘Z still works after Source↔Visual↔Preview).
    private func setEditorMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        document.commitContentEdit()
        if newMode != .visual {
            stripActions.insertTable = nil
            stripActions.tableAddRow = nil
            stripActions.tableDeleteRow = nil
            stripActions.formulaStub = nil
        }
        storedMode = newMode.rawValue
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if sidebarVisible && allowsSidebar {
                    WorkspaceSidebar(
                        workspace: workspace,
                        outlineContent: document.content,
                        activeURL: fileURL,
                        onOpen: openFromSidebar,
                        onOpenFolder: { AppState.shared.openInMainWindow($0) },
                        onJump: { offset in positionStore.requestJump(toMarkdownOffset: offset) }
                    )
                    .frame(width: sidebarWidth)
                    paneDivider(space: .global) { x in
                        sidebarWidth = min(Self.sidebarWidthRange.upperBound,
                                           max(Self.sidebarWidthRange.lowerBound, Double(x)))
                    }
                    // draw/hit above the editor column: without this the
                    // editor (drawn last) shadows the right half of the
                    // 12pt grab strip (agterm's sidebar-divider lesson).
                    .zIndex(1)
                }
                editorArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // animate collapse/expand uniformly, whatever flips the flag
            // (toolbar button, View menu ⌃⌘S).
            .animation(.easeInOut(duration: 0.15), value: sidebarVisible)
            statusBar
        }
        .preferredColorScheme(editorSettings.general.appearance.colorScheme)
        .toolbar { toolbarContent }
        .focusedSceneValue(\.formatActions, mode == .preview ? nil : formatActions)
        .focusedSceneValue(\.editorMode, modeBinding)
        .focusedSceneValue(\.sidebarVisible, $sidebarVisible)
        .focusedSceneValue(\.splitPreview, splitBinding)
        .focusedSceneValue(\.documentUndoActions, DocumentUndoActions(
            undo: { document.performUndo() },
            redo: { document.performRedo() }
        ))
        .focusedSceneValue(\.documentActions, DocumentActions(
            save: onSave,
            saveAs: onSaveAs,
            hasURL: fileURL != nil,
            presentCommit: (fileURL != nil && gitSnapshot.inRepo)
                ? { showGitCommit = true } : nil,
            presentPush: (fileURL != nil && gitSnapshot.inRepo)
                ? { pushFocusedFile() } : nil,
            canCommit: gitSnapshot.canCommit,
            canPush: gitSnapshot.canPush
        ))
        .onDisappear {
            document.commitContentEdit()
        }
        .sheet(isPresented: $showExternalDiff) {
            if let notice = externalChanges.notice(for: fileURL) {
                UnifiedDiffSheet(notice: notice, onClose: { showExternalDiff = false })
            } else {
                // Notice dismissed while sheet was opening.
                Text("No external change")
                    .padding()
                    .onAppear { showExternalDiff = false }
            }
        }
        .sheet(isPresented: $showGitCommit) {
            if let url = fileURL {
                GitCommitSheet(
                    fileURL: url,
                    documentContent: document.content,
                    onClose: {
                        showGitCommit = false
                        refreshGitSnapshot()
                    },
                    onCommitted: { refreshGitSnapshot() }
                )
            } else {
                Text("No file")
                    .padding()
                    .onAppear { showGitCommit = false }
            }
        }
        .onChange(of: externalChanges.notice(for: fileURL)?.id) { _ in
            // Close the sheet if the notice goes away under us.
            if externalChanges.notice(for: fileURL) == nil {
                showExternalDiff = false
            }
        }
        .onAppear { refreshGitSnapshot() }
        .onChange(of: fileURL) { _ in refreshGitSnapshot() }
        .onChange(of: lineChanges.revision) { _ in refreshGitSnapshot() }
        .onReceive(NotificationCenter.default.publisher(for: .gitRepositoryDidChange)) { _ in
            refreshGitSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshGitSnapshot()
        }
    }

    private func refreshGitSnapshot() {
        // Coalesce keystroke-driven mark updates so we don't spawn git on every char.
        gitRefreshTask?.cancel()
        let url = fileURL
        gitRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            gitSnapshot = GitFileStatus.snapshot(for: url)
        }
    }

    private func pushFocusedFile() {
        guard let url = fileURL else { return }
        GitPushConfirm.run(for: url)
        refreshGitSnapshot()
    }

    // MARK: - External change banner actions

    private func handleExternalPrimary(_ notice: ExternalChangeNotice) {
        showExternalDiff = false
        switch notice.kind {
        case .applied:
            // Buffer already matches disk — just dismiss.
            DocumentRegistry.shared.dismissExternalChange(notice.url)
        case .conflict:
            DocumentRegistry.shared.applyExternalContent(notice.url, content: notice.after)
        }
    }

    private func handleExternalSecondary(_ notice: ExternalChangeNotice) {
        showExternalDiff = false
        switch notice.kind {
        case .applied:
            // Restore pre-reload text and write it back to disk.
            DocumentRegistry.shared.revertAppliedExternalChange(
                notice.url, previousContent: notice.before)
        case .conflict:
            try? DocumentRegistry.shared.keepMineOverDisk(notice.url)
        }
    }

    // MARK: - Panes

    /// The editor area right of the sidebar. Preview mode fills it with the
    /// rendered page; otherwise the edit pane, plus — when the split is on —
    /// a divider and a live preview. The edit pane is ALWAYS the HStack's
    /// first child (the split only appends siblings), so toggling the split
    /// keeps its structural identity: the NSTextView is not recreated and
    /// cursor/undo survive.
    /// Mode-specific inset for aligning the strip with the reading column.
    private var stripInset: (h: CGFloat, column: CGFloat) {
        switch mode {
        case .source:
            return (editorSettings.source.insetH, editorSettings.source.columnWidth)
        case .visual:
            return (editorSettings.visual.insetH, editorSettings.visual.columnWidth)
        case .preview:
            return (editorSettings.preview.insetH, editorSettings.preview.columnWidth)
        }
    }

    @ViewBuilder private var editorArea: some View {
        VStack(spacing: 0) {
            EditorActionStrip(actions: stripActions,
                              insetH: stripInset.h,
                              columnWidth: stripInset.column,
                              showVisualExtras: mode == .visual)
            if mode == .preview {
                // Line numbers / dirty marks are baked into the HTML (`data-ln`)
                // so they scroll with the page — no separate rail to sync.
                MarkdownPreviewView(document: document, fileURL: fileURL,
                                    positionStore: positionStore,
                                    onRequestEdit: { setEditorMode(.visual) },
                                    toolbarActions: stripActions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        editorPane
                            .frame(width: splitPreview
                                ? max(160, geo.size.width * splitFraction)
                                : geo.size.width)
                        if splitPreview {
                            paneDivider(space: .named("editorSplit")) { x in
                                splitFraction = min(Self.splitFractionRange.upperBound,
                                                    max(Self.splitFractionRange.lowerBound,
                                                        Double(x) / max(1, Double(geo.size.width))))
                            }
                            .zIndex(1)
                            MarkdownPreviewView(document: document, fileURL: fileURL,
                                                positionStore: positionStore)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .coordinateSpace(name: "editorSplit")
                    .animation(.easeInOut(duration: 0.15), value: splitPreview)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var editorPane: some View {
        switch mode {
        case .source:
            SourceTextView(
                document: document,
                fileURL: fileURL,
                positionStore: positionStore,
                insetH: editorSettings.source.insetH,
                insetV: editorSettings.source.insetV,
                columnWidth: editorSettings.source.columnWidth,
                onStatsUpdate: { w, c in wordCount = w; charCount = c },
                onFormatActions: { actions in
                    formatActions = actions
                    bindStrip(from: actions, visualExtras: false)
                },
                onLintUpdate: { summary in lintSummary = summary }
            )
        case .visual:
            VisualMarkdownView(
                document: document,
                theme: theme,
                fileURL: fileURL,
                positionStore: positionStore,
                onStatsUpdate: { w, c in wordCount = w; charCount = c },
                onFormatActions: { actions in
                    formatActions = actions
                    bindStrip(from: actions, visualExtras: true)
                }
            )
        case .preview:
            // unreachable: editorArea routes .preview to the full preview
            EmptyView()
        }
    }

    /// Mirrors FormatActions into the shared strip bag.
    private func bindStrip(from fa: FormatActions, visualExtras: Bool) {
        stripActions.toggleBold = fa.toggleBold
        stripActions.toggleItalic = fa.toggleItalic
        stripActions.toggleStrikethrough = fa.toggleStrikethrough
        stripActions.toggleHighlight = fa.toggleHighlight
        stripActions.setHeading = fa.setHeading
        stripActions.setBody = fa.setBody
        stripActions.toggleCodeBlock = fa.toggleCodeBlock
        stripActions.toggleBulletList = fa.toggleBulletList
        stripActions.toggleChecklist = fa.toggleChecklist
        stripActions.toggleNumberedList = fa.toggleNumberedList
        stripActions.toggleQuote = fa.toggleQuote
        stripActions.copySelection = fa.copySelection
        if visualExtras {
            stripActions.insertTable = fa.insertTable
            stripActions.tableAddRow = fa.tableAddRow
            stripActions.tableDeleteRow = fa.tableDeleteRow
            stripActions.formulaStub = fa.formulaStub
        } else {
            stripActions.insertTable = nil
            stripActions.tableAddRow = nil
            stripActions.tableDeleteRow = nil
            stripActions.formulaStub = nil
        }
        // No objectWillChange — strip UI is mode-driven; closures are read on tap.
    }

    /// agterm-style divider: a 1px separator with a wider invisible grab
    /// strip. The new position comes from the ABSOLUTE cursor x in `space`,
    /// not accumulated translation — the divider moves with the resize, so
    /// translation-based dragging feeds back on itself and flickers.
    private func paneDivider(space: CoordinateSpace,
                             onDrag: @escaping (CGFloat) -> Void) -> some View {
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
                        DragGesture(minimumDistance: 1, coordinateSpace: space)
                            .onChanged { onDrag($0.location.x) }
                    )
            }
    }

    // MARK: - Toolbar

    /// Flat icon-only buttons with tooltip+shortcut hints and multi-state
    /// SF Symbols (filled while active) — the agterm titlebar button style.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if allowsSidebar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .help("Toggle Sidebar (⌃⌘S)")
            }
        }
        ToolbarItemGroup(placement: .navigation) {
            ForEach(EditorMode.allCases) { candidate in
                Button {
                    setEditorMode(candidate)
                } label: {
                    Label(candidate.title,
                          systemImage: mode == candidate
                              ? candidate.activeSystemImage
                              : candidate.systemImage)
                        .foregroundStyle(mode == candidate ? Color.accentColor : Color.primary)
                }
                // Toolbar already hosts native tooltips via Label; .help is enough.
                .help("\(candidate.title) (\(candidate.shortcutHint))")
            }
        }
        ToolbarItemGroup {
            Button {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            .help("Cut (⌘X)")
            Button {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy (⌘C)")
            Button {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .help("Paste (⌘V)")
        }
        ToolbarItem {
            Button {
                splitBinding.wrappedValue.toggle()
            } label: {
                Label("Split Preview",
                      systemImage: splitPreview ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            }
            .help(splitPreview ? "Hide preview pane (⌥⌘P)" : "Show preview pane (⌥⌘P)")
        }
        ToolbarItem {
            Menu {
                Picker("Theme", selection: $editorSettings.general.themePreset) {
                    Text("System").tag("system")
                    Text("GitHub").tag("github")
                }
                Divider()
                Button("Settings…") {
                    // macOS 14+ uses showSettingsWindow:; 13 uses the older
                    // showPreferencesWindow:.
                    if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }
            .help("Editor theme & settings")
        }
        ToolbarItem {
            Button {
                editorSettings.general.appearance = appearanceIsDark ? .light : .dark
            } label: {
                Label("Appearance", systemImage: appearanceIsDark ? "moon" : "sun.max")
            }
            .help(appearanceIsDark ? "Switch to light appearance" : "Switch to dark appearance")
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        // Preview has no editor callbacks — count directly from the document.
        let (words, chars) = mode == .preview
            ? wordAndCharCount(in: document.content)
            : (wordCount, charCount)
        return HStack(spacing: 10) {
            if mode == .source, let summary = lintSummary,
               summary.errorCount + summary.warningCount > 0 {
                Button {
                    summary.jumpToNext()
                } label: {
                    HStack(spacing: 8) {
                        if summary.errorCount > 0 {
                            Text("✕ \(summary.errorCount)").foregroundStyle(.red)
                        }
                        if summary.warningCount > 0 {
                            Text("⚠ \(summary.warningCount)").foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .editMDHelp("Jump to the next issue")
            }
            Spacer(minLength: 8)
            // External disk change — compact chip left of word count.
            if let notice = externalChanges.notice(for: fileURL) {
                ExternalChangeStatusChip(
                    notice: notice,
                    onShowDiff: { showExternalDiff = true },
                    onPrimary: { handleExternalPrimary(notice) },
                    onSecondary: { handleExternalSecondary(notice) },
                    onDismiss: { DocumentRegistry.shared.dismissExternalChange(notice.url) }
                )
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
            }
            // Git: commit this file / push (stages 4–5).
            if gitSnapshot.inRepo {
                GitStatusChip(
                    snapshot: gitSnapshot,
                    onCommit: { showGitCommit = true },
                    onPush: { pushFocusedFile() }
                )
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
            }
            Text("\(words) words  \(chars) chars")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Sidebar open

    /// Left-click a file in the sidebar. If it's already open in another window,
    /// ask whether to jump there or move it here (closing the other); otherwise
    /// replace the main window's file in place.
    private func openFromSidebar(_ url: URL) {
        let std = url.standardizedFileURL
        if std == fileURL?.standardizedFileURL { return }
        if let other = NSApp.windows.first(where: {
            $0 !== NSApp.keyWindow && $0.isVisible
                && $0.representedURL?.standardizedFileURL == std
        }) {
            presentAlreadyOpenModal(url: std, other: other)
        } else {
            AppState.shared.openInMainWindow(std)
        }
    }

    private func presentAlreadyOpenModal(url: URL, other: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "«\(url.lastPathComponent)» уже открыт в другом окне"
        alert.informativeText = "Перейти к тому окну или открыть здесь и закрыть то?"
        alert.addButton(withTitle: "Перейти к нему")
        alert.addButton(withTitle: "Открыть здесь")
        alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            other.makeKeyAndOrderFront(nil)
        case .alertSecondButtonReturn:
            AppState.shared.openInMainWindow(url)
            other.close()
        default:
            break
        }
    }
}
