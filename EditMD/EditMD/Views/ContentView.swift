import SwiftUI

func builtInPluginConfigurationDiagnosticsForStatusBar(
    mode: EditorMode,
    markdown: String
) -> [BuiltInPluginConfigurationDiagnostic] {
    guard mode == .visual else { return [] }
    return BuiltInPluginRegistry.configurationDiagnostics(in: markdown)
}

/// Width the flexible editor column keeps before the side panels start to
/// shrink. Chosen so a usable reading measure survives with BOTH panels open
/// (at their 150pt floor each, the clamp only engages below ~562pt window
/// width). This governs the editor vs. the side panels; it is unrelated to the
/// Source/Preview split's own 160pt pane floor, which divides space *inside*
/// the editor area.
let editorColumnMinWidth: CGFloat = 260

/// Floor for the main workspace window. Pane clamp only prevents *overlap*;
/// without a window min the user can still drag the frame until the editor is
/// a mid-word wrapping strip while both side panels stay open. 900 leaves a
/// readable ~450pt editor at default panel widths (220+220+2); 720 was still
/// too tight in practice (title/body mid-word wrap, strip buttons clipped).
/// Enforced via `NSWindow.contentMinSize` — SwiftUI `.frame(minWidth:)` alone
/// does not reliably stop live resize on `Window` scenes.
let mainWindowMinWidth: CGFloat = 900
let mainWindowMinHeight: CGFloat = 420

/// Lite windows have no workspace sidebar (inspector still optional), so they
/// can be narrower than the main workspace.
let liteWindowMinWidth: CGFloat = 560
let liteWindowMinHeight: CGFloat = 360

struct ResolvedPaneWidths: Equatable {
    var sidebar: CGFloat
    var inspector: CGFloat
    /// Display / preferred ratio: 1 when the panels fit, <1 while compressed.
    /// Divider drags invert through it so a resize writes a *preferred* width
    /// (see `preferredPaneWidthFromDrag`).
    var scale: CGFloat
}

/// Clamp the fixed side-panel widths to the available width so the flexible
/// editor column keeps at least `editorMin`. SwiftUI's `HStack` will not
/// compress a rigid `.frame(width:)`, so when the window is too narrow the
/// panels overflow their slots and draw on top of the editor / each other
/// (reported as the inspector overlapping neighbouring panes). Shrinking the
/// panels proportionally into the leftover budget keeps every pane side-by-side.
/// The stored (requested) widths are untouched, so panels restore when the
/// window widens again.
func resolveSidePaneWidths(
    available: CGFloat,
    sidebarWidth: CGFloat,
    inspectorWidth: CGFloat,
    sidebarVisible: Bool,
    inspectorVisible: Bool,
    editorMin: CGFloat = editorColumnMinWidth,
    dividerWidth: CGFloat = 1
) -> ResolvedPaneWidths {
    let sidebar = sidebarVisible ? max(0, sidebarWidth) : 0
    let inspector = inspectorVisible ? max(0, inspectorWidth) : 0
    let requested = sidebar + inspector
    guard requested > 0 else {
        return ResolvedPaneWidths(sidebar: 0, inspector: 0, scale: 1)
    }
    let dividers = (sidebarVisible ? dividerWidth : 0)
        + (inspectorVisible ? dividerWidth : 0)
    // How much width the panels may occupy while leaving the editor its floor.
    let budget = max(0, available - dividers - editorMin)
    guard requested > budget else {
        return ResolvedPaneWidths(sidebar: sidebar, inspector: inspector, scale: 1)
    }
    // Overflow: scale both panels down proportionally into the budget so their
    // sum never exceeds what the editor can spare — no pane overlaps another.
    let scale = budget / requested
    return ResolvedPaneWidths(
        sidebar: sidebar * scale, inspector: inspector * scale, scale: scale)
}

/// Map a divider drag back to a *preferred* (stored) panel width. The grab
/// strip sits at the panel's DISPLAY edge, which in a clamped window is the
/// shrunken width (`preferred * scale`). Writing the raw display width into
/// storage would overwrite the preferred width with the compressed one — a
/// no-op drag would collapse a stored 220 down to ~119 and break "restore on
/// widen". Dividing by `scale` inverts the clamp, so a drag that does not move
/// leaves the stored width unchanged, and a real drag scales into preferred
/// space before the range clamp.
func preferredPaneWidthFromDrag(
    displayWidth: CGFloat,
    scale: CGFloat,
    range: ClosedRange<Double>
) -> Double {
    let s = scale > 0 ? Double(scale) : 1
    let preferred = Double(displayWidth) / s
    return min(range.upperBound, max(range.lowerBound, preferred))
}

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
    /// Left workspace sidebar show/hide (the sidebar itself + its width live in
    /// `MainChrome`; this window still flips visibility, e.g. the Git chip).
    @AppStorage("sidebarVisible") private var sidebarVisible = false
    @AppStorage("sidebarTab") private var sidebarTab = "files"
    /// Right document-scope inspector (Outline / Info / …).
    @AppStorage("inspectorVisible") private var inspectorVisible = false
    @AppStorage("inspectorWidth") private var inspectorWidth = 220.0
    @AppStorage("inspectorTab") private var inspectorTab = "outline"
    /// Dedicated Source + Preview mode: edit pane's share of the split.
    @AppStorage("splitFraction") private var splitFraction = 0.5
    @ObservedObject private var editorSettings = EditorSettings.shared
    @ObservedObject private var workspace = WorkspaceModel.shared
    @ObservedObject private var externalChanges = ExternalChangeCenter.shared
    @ObservedObject private var lineChanges = LineChangeTracker.shared
    @State private var wordCount = 0
    @State private var charCount = 0
    @State private var formatActions: FormatActions?
    @State private var lintSummary: LintSummary?
    /// Left edge of the text reported by Source/Visual (their reading inset —
    /// it already reserves the numbers margin). Preview computes its own.
    @State private var editorTextLeading: CGFloat = 0
    @State private var showLintPopover = false
    @State private var positionStore = EditorPositionStore()
    /// Shared Notes-style action strip (all three modes). Held in a ref box so
    /// rebinding closures does not trigger SwiftUI view updates.
    @State private var stripActions = EditorStripActions()
    /// B6: strip B/I/`/S accent state (updated from editor caret callbacks).
    @State private var activeFormats = ActiveInlineFormats()
    /// ⌘F find state for full Preview mode (sprint 5). Driven by the Edit ▸ Find
    /// menu via a focused value, and by the overlaid `PreviewFindBar`.
    @StateObject private var previewFind = PreviewFindModel()
    @State private var showExternalDiff = false
    @State private var showGitCommit = false
    @State private var gitSnapshot = GitFileSnapshot.empty
    @State private var gitRefreshTask: Task<Void, Never>?

    private static let inspectorWidthRange = 150.0...400.0
    private static let splitFractionRange = 0.25...0.75

    private var mode: EditorMode { EditorMode(rawValue: storedMode) ?? .preview }

    /// The active Source/Visual look: the single fixed editor theme plus
    /// General's base color overrides. (Preview has its own `PreviewTheme`.)
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

    /// Edit ▸ Find bridge for the active full Preview (sprint 5). Published only
    /// while `mode == .preview`; Source/Visual keep the native `NSTextFinder`.
    private var previewFindActions: PreviewFindActions {
        PreviewFindActions(
            show: { previewFind.activate() },
            findNext: { previewFind.next() },
            findPrevious: { previewFind.previous() },
            useSelectionForFind: { previewFind.useSelectionForFind() }
        )
    }

    /// Switch editor mode after flushing any coalesced typing onto the
    /// document undo stack (so ⌘Z still works after Source↔Visual↔Preview).
    private func setEditorMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        document.commitContentEdit()
        // Leaving Preview retires its ⌘F find bar and highlights.
        if newMode != .preview { previewFind.close() }
        if newMode != .visual {
            stripActions.insertTable = nil
            stripActions.tableAddRow = nil
            stripActions.tableDeleteRow = nil
            stripActions.tableAddColumn = nil
            stripActions.tableDeleteColumn = nil
            stripActions.insertInlineFormula = nil
            stripActions.insertBlockFormula = nil
        }
        storedMode = newMode.rawValue
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                // The left workspace sidebar lives in `MainChrome` (a stable
                // parent that is NOT `.id`-swapped per file), so it survives file
                // switches — no teardown, so its scroll / selection / filter
                // persist (A1). Here we only lay out the editor + right inspector,
                // and clamp the inspector against the editor's floor.
                let panes = resolveSidePaneWidths(
                    available: geo.size.width,
                    sidebarWidth: 0,
                    inspectorWidth: inspectorWidth,
                    sidebarVisible: false,
                    inspectorVisible: inspectorVisible)
                HStack(spacing: 0) {
                    editorArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if inspectorVisible {
                        // Grab strip LEFT of the right panel.
                        paneDivider(space: .named("mainPanes")) { x in
                            // Inspector is last: its display width is the span from
                            // the divider to the right edge. Invert the clamp too.
                            inspectorWidth = preferredPaneWidthFromDrag(
                                displayWidth: geo.size.width - x, scale: panes.scale,
                                range: Self.inspectorWidthRange)
                        }
                        .zIndex(1)
                        InspectorSidebar(
                            fileURL: fileURL,
                            outlineContent: document.content,
                            document: document,
                            gitSnapshot: gitSnapshot,
                            hasWorkspace: !workspace.workspaces.isEmpty,
                            onJump: { offset in
                                positionStore.requestJump(toMarkdownOffset: offset)
                            },
                            onOpen: openFromSidebar,
                            onOpenInSource: { offset in
                                setEditorMode(.source)
                                positionStore.requestJump(toMarkdownOffset: offset)
                            },
                            onHistoryRestore: { oldContent, baseline in
                                restoreFromHistory(oldContent: oldContent,
                                                   baseline: baseline)
                            }
                        )
                        .frame(width: panes.inspector)
                    }
                }
                .coordinateSpace(name: "mainPanes")
                .animation(.easeInOut(duration: 0.15), value: inspectorVisible)
            }
            statusBar
        }
        // Appearance override lives on the window root (MainWindowView /
        // LiteWindowContent) so non-editor panes follow it too. The sidebar
        // toggle is provided once by `MainChrome`, not here.
        .toolbar {
            EditorToolbar(
                editorSettings: editorSettings,
                appearanceIsDark: appearanceIsDark
            )
        }
        .agentActivityToast()
        .focusedSceneValue(\.formatActions, mode == .preview ? nil : formatActions)
        .focusedSceneValue(\.previewFind, mode == .preview ? previewFindActions : nil)
        .focusedSceneValue(\.editorMode, modeBinding)
        .focusedSceneValue(\.inspectorVisible, $inspectorVisible)
        .focusedSceneValue(\.documentUndoActions, DocumentUndoActions(
            undo: { document.performUndo() },
            redo: { document.performRedo() }
        ))
        .focusedSceneValue(\.documentActions, DocumentActions(
            save: onSave,
            saveAs: onSaveAs,
            hasURL: fileURL != nil,
            markdownContent: { [document] in document.content },
            fileURL: fileURL,
            prepareForExport: { [document] in document.commitContentEdit() },
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
                    onClose: {
                        showGitCommit = false
                        GitHeadContentCache.invalidate(url: url)
                        refreshGitSnapshot(mode: .full, delayMs: 0)
                    },
                    onCommitted: {
                        GitHeadContentCache.invalidate(url: url)
                        refreshGitSnapshot(mode: .full, delayMs: 0)
                    }
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
        .onAppear {
            refreshGitSnapshot(mode: .full, delayMs: 0)
            if isMain {
                ClaudeIDEBridge.shared.setActiveURL(fileURL)
                ReviewModel.shared.setActiveFile(fileURL, text: document.content)
                consumePendingControlJump()
            }
        }
        .onChange(of: fileURL) { _ in
            // A different file is now on screen — the old find no longer applies.
            previewFind.close()
            GitHeadContentCache.invalidate()
            refreshGitSnapshot(mode: .full, delayMs: 0)
            if isMain {
                ClaudeIDEBridge.shared.setActiveURL(fileURL)
                ReviewModel.shared.setActiveFile(fileURL, text: document.content)
                consumePendingControlJump()
            }
        }
        // Session marks only — no git Process (delta reuses cached HEAD).
        .onChange(of: lineChanges.revision) { _ in
            refreshGitSnapshot(mode: .deltaOnly, delayMs: 350)
        }
        // Typing: update +/− only; never re-run status/branch/ahead-behind.
        .onChange(of: document.content) { _ in
            refreshGitSnapshot(mode: .deltaOnly, delayMs: 450)
            // Keep review anchors resolving against the live buffer (cheap: a
            // String assignment; recompute only happens while the tab is shown).
            if isMain { ReviewModel.shared.setActiveFile(fileURL, text: document.content) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gitRepositoryDidChange)) { note in
            if let url = note.object as? URL {
                GitHeadContentCache.invalidate(url: url)
            } else {
                GitHeadContentCache.invalidate()
            }
            refreshGitSnapshot(mode: .full, delayMs: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Meta may have changed in Terminal; keep debounce light.
            refreshGitSnapshot(mode: .full, delayMs: 200)
            // The sidecar may have been rewritten out-of-band (Claude `/smotr
            // -pr`, or the smotr web view) — pick up new replies / suggestions.
            if isMain { ReviewModel.shared.reload() }
        }
        // editmdctl open/reveal → jump to markdown offset in this window.
        // The offset waits in AppState until the target file is mounted here
        // (also consumed from onAppear / fileURL change) — no timers, no
        // dropped jumps on slow opens.
        .onReceive(NotificationCenter.default.publisher(for: .editMDControlJump)) { _ in
            consumePendingControlJump()
        }
    }

    /// Claims AppState's pending control jump when it targets this window's
    /// file. Deferred one runloop turn so SwiftUI finishes mounting/reloading
    /// the editors for the new file before they are poked.
    private func consumePendingControlJump() {
        guard isMain,
              let offset = AppState.shared.consumeControlJump(for: fileURL) else { return }
        DispatchQueue.main.async {
            positionStore.requestJump(toMarkdownOffset: offset)
        }
    }

    /// - Parameters:
    ///   - mode: `.full` = git status/branch/ahead; `.deltaOnly` = +/− from cached HEAD + buffer.
    ///   - delayMs: coalesce keystroke storms (delta) vs immediate meta refresh.
    private func refreshGitSnapshot(mode: GitSnapshotRefresh = .full, delayMs: UInt64 = 250) {
        gitRefreshTask?.cancel()
        let url = fileURL
        let buffer = document.content
        let previous = gitSnapshot
        gitRefreshTask = Task { @MainActor in
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            let next = await GitFileStatus.snapshot(
                for: url, buffer: buffer, previous: previous, mode: mode
            )
            guard !Task.isCancelled else { return }
            gitSnapshot = next
        }
    }

    private func pushFocusedFile() {
        guard let url = fileURL else { return }
        // Off-main; a successful push posts .gitRepositoryDidChange, which the
        // onReceive above turns into invalidate + full snapshot refresh.
        GitPushConfirm.run(for: url)
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

    /// The editor area right of the sidebar. Split is a first-class mode with a
    /// fixed Source pane on the left and Preview on the right; Visual is never
    /// mounted beside Preview.
    /// Mode-specific inset for aligning the strip with the reading column.
    private var stripInset: (h: CGFloat, column: CGFloat) {
        switch mode {
        case .source:
            return (editorSettings.source.insetH, editorSettings.source.columnWidth)
        case .visual:
            return (editorSettings.visual.insetH, editorSettings.visual.columnWidth)
        case .preview:
            return (editorSettings.preview.insetH, editorSettings.preview.columnWidth)
        case .split:
            return (editorSettings.source.insetH, editorSettings.source.columnWidth)
        }
    }

    /// Same numbers the Preview CSS uses for its line-number rail — the strip
    /// mirrors them instead of guessing.
    private var previewRailWidth: CGFloat {
        let g = editorSettings.gutter
        let options = PreviewGutterOptions(
            showLineNumbers: g.showLineNumbers,
            highlightChangedLines: g.highlightChangedLines,
            showDirtyBulletsWhenNoNumbers: g.showDirtyBulletsWhenNoNumbers,
            dirtyLines: lineChanges.dirtyLines(for: fileURL)
        )
        return PreviewGutterMetrics.railPx(for: options)
    }

    @ViewBuilder private var editorArea: some View {
        GeometryReader { geo in
            let splitEditorWidth = max(160, geo.size.width * splitFraction)
            VStack(spacing: 0) {
                EditorActionStrip(actions: stripActions,
                                  insetH: stripInset.h,
                                  columnWidth: stripInset.column,
                                  editingPaneWidth: mode == .split ? splitEditorWidth : nil,
                                  textLeading: mode == .preview ? nil : editorTextLeading,
                                  railGap: mode == .preview
                                      ? PreviewGutterMetrics.gapPx : GutterMetrics.gap,
                                  previewRailWidth: mode == .preview ? previewRailWidth : 0,
                                  showVisualExtras: mode == .visual,
                                  showReviewAction: allowsSidebar,
                                  addReviewMark: requestReviewMark,
                                  activeFormats: activeFormats,
                                  mode: mode,
                                  setEditorMode: setEditorMode,
                                  showLineNumbers: editorSettings.gutter.showLineNumbers,
                                  toggleLineNumbers: {
                                      editorSettings.gutter.showLineNumbers.toggle()
                                  })
                switch mode {
                case .preview:
                    // Line numbers / dirty marks are baked into the HTML (`data-ln`)
                    // so they scroll with the page — no separate rail to sync.
                    MarkdownPreviewView(document: document, fileURL: fileURL,
                                        positionStore: positionStore,
                                        onRequestEdit: { setEditorMode(.visual) },
                                        toolbarActions: stripActions,
                                        onActiveFormats: { activeFormats = $0 },
                                        findModel: previewFind)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .topTrailing) {
                            if previewFind.isActive {
                                PreviewFindBar(model: previewFind)
                                    .padding(.top, 8)
                                    .padding(.trailing, 14)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .animation(.easeOut(duration: 0.12), value: previewFind.isActive)
                case .split:
                    HStack(spacing: 0) {
                        editorPane
                            .frame(width: splitEditorWidth)
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
                    .coordinateSpace(name: "editorSplit")
                case .source, .visual:
                    editorPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder private var editorPane: some View {
        switch mode {
        case .source:
            sourceEditorPane(syncsPreview: false)
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
                },
                onActiveFormats: { activeFormats = $0 },
                onTextLeading: { editorTextLeading = $0 }
            )
        case .preview:
            // unreachable: editorArea routes .preview to the full preview
            EmptyView()
        case .split:
            sourceEditorPane(syncsPreview: true)
        }
    }

    private func sourceEditorPane(syncsPreview: Bool) -> some View {
        let visibleOffset: ((Double) -> Void)? = syncsPreview
            ? { position in
                positionStore.requestPreviewScroll(toMarkdownPosition: position)
            }
            : nil
        return SourceTextView(
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
            onLintUpdate: { summary in lintSummary = summary },
            onActiveFormats: { activeFormats = $0 },
            onVisibleOffset: visibleOffset,
            onTextLeading: { editorTextLeading = $0 }
        )
    }

    /// Mirrors FormatActions into the shared strip bag.
    private func bindStrip(from fa: FormatActions, visualExtras: Bool) {
        stripActions.toggleBold = fa.toggleBold
        stripActions.toggleItalic = fa.toggleItalic
        stripActions.toggleStrikethrough = fa.toggleStrikethrough
        stripActions.toggleCodeSpan = fa.toggleCodeSpan
        stripActions.toggleHighlight = fa.toggleHighlight
        stripActions.setHeading = fa.setHeading
        stripActions.setBody = fa.setBody
        stripActions.clearInlineFormatting = fa.clearInlineFormatting
        stripActions.insertDivider = fa.insertDivider
        stripActions.cycleCase = fa.cycleCase
        stripActions.toggleCodeBlock = fa.toggleCodeBlock
        stripActions.toggleBulletList = fa.toggleBulletList
        stripActions.toggleChecklist = fa.toggleChecklist
        stripActions.toggleNumberedList = fa.toggleNumberedList
        stripActions.toggleQuote = fa.toggleQuote
        stripActions.insertImage = fa.insertImage
        if visualExtras {
            stripActions.insertTable = fa.insertTable
            stripActions.tableAddRow = fa.tableAddRow
            stripActions.tableDeleteRow = fa.tableDeleteRow
            stripActions.tableAddColumn = fa.tableAddColumn
            stripActions.tableDeleteColumn = fa.tableDeleteColumn
            stripActions.insertInlineFormula = fa.insertInlineFormula
            stripActions.insertBlockFormula = fa.insertBlockFormula
        } else {
            stripActions.insertTable = nil
            stripActions.tableAddRow = nil
            stripActions.tableDeleteRow = nil
            stripActions.tableAddColumn = nil
            stripActions.tableDeleteColumn = nil
            stripActions.insertInlineFormula = nil
            stripActions.insertBlockFormula = nil
        }
        // No objectWillChange — strip UI is mode-driven; closures are read on tap.
    }

    /// The Preview/Split review button reuses the inspector's existing compose form.
    /// The model keeps the request until the Review tab appears, avoiding a
    /// race when this action also opens a previously hidden sidebar.
    private func requestReviewMark() {
        guard allowsSidebar, mode == .preview || mode == .split else { return }
        inspectorVisible = true
        inspectorTab = "review"
        ReviewModel.shared.requestCompose()
    }

    /// History tab restore: undoable whole-document replace. Rejects if the
    /// buffer changed since the diff preview was opened.
    private func restoreFromHistory(oldContent: String, baseline: String) {
        guard canApplyHistoryRestore(previewBaseline: baseline,
                                     currentContent: document.content) else {
            let alert = NSAlert()
            alert.messageText = String(localized: "The document has changed")
            alert.informativeText =
                String(localized: "Reopen the diff to restore this revision.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        document.applyDocumentEdit(oldContent, actionName: "Restore Revision")
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

    // MARK: - Status bar

    private var statusBar: some View {
        // Preview has no editor callbacks — count directly from the document.
        let (words, chars) = mode == .preview
            ? wordAndCharCount(in: document.content)
            : (wordCount, charCount)
        let pluginDiagnostics = builtInPluginConfigurationDiagnosticsForStatusBar(
            mode: mode, markdown: document.content)
        return HStack(spacing: 10) {
            // D2: always-on lint chip in Source (checkmark when clean).
            if mode == .source || mode == .split {
                lintStatusChip
            }
            if !pluginDiagnostics.isEmpty {
                BuiltInPluginConfigurationStatusChip(
                    diagnostics: pluginDiagnostics,
                    onOpenSource: {
                        positionStore.markdownOffset = 0
                        setEditorMode(.source)
                    })
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
            // Workspace background work (link index scan, vault-lint run).
            BackgroundActivityChip()
            // Claude Code: grey while listening, accent once /ide attached.
            ClaudeIDEChip()
            // Git: info only (Commit / Push live in the Git sidebar tab).
            if gitSnapshot.inRepo {
                GitStatusChip(snapshot: gitSnapshot) {
                    guard allowsSidebar else { return }
                    sidebarVisible = true
                    sidebarTab = "git"
                }
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

    // MARK: - Lint status (D2)

    @ViewBuilder private var lintStatusChip: some View {
        let summary = lintSummary
        let errors = summary?.errorCount ?? 0
        let warnings = summary?.warningCount ?? 0
        let total = errors + warnings
        Button {
            if total > 0 {
                showLintPopover.toggle()
            } else {
                summary?.jumpToNext()
            }
        } label: {
            HStack(spacing: 4) {
                if total == 0 {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("0")
                        .foregroundStyle(.secondary)
                } else {
                    if errors > 0 {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("\(errors)")
                            .foregroundStyle(.red)
                    }
                    if warnings > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(warnings)")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .editMDHelp(total == 0 ? "No lint issues" : "Show lint issues")
        .popover(isPresented: $showLintPopover, arrowEdge: .top) {
            lintPopoverContent
                .frame(minWidth: 320, idealWidth: 380, maxHeight: 360)
        }
    }

    @ViewBuilder private var lintPopoverContent: some View {
        let diags = lintSummary?.diagnostics ?? []
        if diags.isEmpty {
            Text("No issues")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            List {
                ForEach(Array(diags.enumerated()), id: \.offset) { _, d in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: d.severity == .error
                              ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(d.severity == .error ? Color.red : Color.orange)
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.message)
                                .font(.system(size: 12))
                                .lineLimit(3)
                            Text("\(d.rule.rawValue) · line \(lineNumber(for: d.range))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let fix = d.fixes.first {
                            Button(fix.title) {
                                lintSummary?.applyFirstFix?(d)
                                showLintPopover = false
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.borderless)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        lintSummary?.jumpTo?(d)
                        showLintPopover = false
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func lineNumber(for range: NSRange) -> Int {
        let ns = document.content as NSString
        guard range.location <= ns.length else { return 1 }
        var line = 1
        var i = 0
        while i < range.location && i < ns.length {
            if ns.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        return line
    }

    // MARK: - Sidebar open

    /// Inspector's onOpen reuses the shared workspace-sidebar open routing,
    /// anchored on the file currently on screen.
    private func openFromSidebar(_ url: URL) {
        openFileFromWorkspaceSidebar(url, currentURL: fileURL)
    }
}

// MARK: - Shared workspace-sidebar open routing

/// Left-click a file in the workspace sidebar (or inspector). If it's already
/// open in another window, ask whether to jump there or move it here (closing
/// the other); otherwise replace the main window's file in place. Free function
/// so `MainChrome` (which owns the hoisted sidebar) and `ContentView` (the
/// inspector) share one behaviour.
@MainActor
func openFileFromWorkspaceSidebar(_ url: URL, currentURL: URL?) {
    let std = url.standardizedFileURL
    if std == currentURL?.standardizedFileURL { return }
    if let other = NSApp.windows.first(where: {
        $0 !== NSApp.keyWindow && $0.isVisible
            && $0.representedURL?.standardizedFileURL == std
    }) {
        presentAlreadyOpenModal(url: std, other: other)
    } else {
        AppState.shared.openInMainWindow(std)
    }
}

@MainActor
private func presentAlreadyOpenModal(url: URL, other: NSWindow) {
    let alert = NSAlert()
    alert.messageText = String(localized: "“\(url.lastPathComponent)” is already open in another window")
    alert.informativeText = String(localized: "Switch to that window, or open here and close it?")
    alert.addButton(withTitle: String(localized: "Switch to It"))
    alert.addButton(withTitle: String(localized: "Open Here"))
    alert.addButton(withTitle: String(localized: "Cancel"))
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

private struct BuiltInPluginConfigurationStatusChip: View {
    let diagnostics: [BuiltInPluginConfigurationDiagnostic]
    let onOpenSource: () -> Void

    var body: some View {
        Button(action: onOpenSource) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Plugin configuration needs attention")
        .accessibilityHint("Open Source to fix the plugin frontmatter")
        .editMDHelp(helpText)
    }

    private var title: String {
        guard diagnostics.count == 1, let diagnostic = diagnostics.first else {
            return "\(diagnostics.count) plugins · Needs attention"
        }
        return "\(diagnostic.descriptor.name) · Needs attention"
    }

    private var helpText: String {
        diagnostics.map { "\($0.descriptor.name): \($0.message)" }
            .joined(separator: "\n") + "\nOpen Source to fix frontmatter"
    }
}
