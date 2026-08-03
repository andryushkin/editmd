import SwiftUI
import WebKit

func builtInPluginConfigurationDiagnosticsForStatusBar(
    mode: EditorMode,
    markdown: String
) -> [BuiltInPluginConfigurationDiagnostic] {
    guard mode == .visual else { return [] }
    return BuiltInPluginRegistry.configurationDiagnostics(in: markdown)
}

/// Editor-column floor before side panels shrink. Unrelated to the
/// Source/Preview split's own 160pt pane floor (that divides space *inside*
/// the editor area).
let editorColumnMinWidth: CGFloat = 260

/// Main-window floor. Pane clamp only prevents *overlap*, not a mid-word
/// wrapping editor strip; 900 leaves ~398pt editor at default panel widths
/// (720 was too tight in practice). Enforced via `NSWindow.contentMinSize` —
/// `.frame(minWidth:)` alone does not reliably stop live resize on `Window`
/// scenes.
let mainWindowMinWidth: CGFloat = 900
let mainWindowMinHeight: CGFloat = 420

/// Lite windows have no workspace sidebar, so they can be narrower.
let liteWindowMinWidth: CGFloat = 560
let liteWindowMinHeight: CGFloat = 360

/// Fixed reading-width cap; `max` in `sidePaneWidthRange` keeps the range
/// valid if a navigator strip ever outgrows it (ClosedRange lower > upper
/// traps at runtime).
let sidePaneWidthCeiling: Double = 400

func sidePaneWidthRange(floor: CGFloat) -> ClosedRange<Double> {
    let lower = Double(floor)
    return lower...max(lower, sidePaneWidthCeiling)
}

/// Clamp on read: stored widths predate the current floors, so a never-dragged
/// pane would keep painting its navigator strip clipped.
func clampPaneWidth(_ width: Double, to range: ClosedRange<Double>) -> Double {
    min(range.upperBound, max(range.lowerBound, width))
}

/// Right-inspector geometry, shared: editor host and folder host write the
/// SAME `inspectorWidth` default.
enum InspectorPane {
    /// Floor = navigator-strip width (narrower clips trailing tabs). Bounds
    /// the *preferred* width; display can dip below it when compressed — see
    /// `resolveSidePaneWidths`.
    static var widthRange: ClosedRange<Double> {
        sidePaneWidthRange(floor: InspectorSidebar.minimumPaneWidth)
    }
    static var defaultWidth: Double {
        min(widthRange.upperBound, max(280, widthRange.lowerBound))
    }

    static func clampWidth(_ width: Double) -> Double {
        clampPaneWidth(width, to: widthRange)
    }
}

struct ResolvedPaneWidths: Equatable {
    var sidebar: CGFloat
    var inspector: CGFloat
    /// Display/preferred ratio: 1 when panels fit, <1 compressed. Divider
    /// drags invert through it (`preferredPaneWidthFromDrag`).
    var scale: CGFloat
}

/// Clamp side-panel widths so the flexible editor keeps `editorMin`: HStack
/// never compresses a rigid `.frame(width:)`, so overflowing panels would draw
/// on top of the editor / each other. Panels shrink proportionally; stored
/// widths stay untouched so they restore on widen. Deliberately ignores the
/// panes' navigator floors (those bound *dragging*): honouring them here would
/// push the editor below `editorMin`, so a compressed pane may clip a trailing
/// tab — accepted degraded state.
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
    let budget = max(0, available - dividers - editorMin)
    guard requested > budget else {
        return ResolvedPaneWidths(sidebar: sidebar, inspector: inspector, scale: 1)
    }
    let scale = budget / requested
    return ResolvedPaneWidths(
        sidebar: sidebar * scale, inspector: inspector * scale, scale: scale)
}

/// Map a divider drag back to the *preferred* (stored) width. The grab strip
/// sits at the DISPLAY edge (`preferred * scale`); writing raw display width
/// would overwrite the preferred width with the compressed one and break
/// restore-on-widen. Dividing by `scale` inverts the clamp.
func preferredPaneWidthFromDrag(
    displayWidth: CGFloat,
    scale: CGFloat,
    range: ClosedRange<Double>
) -> Double {
    let s = scale > 0 ? Double(scale) : 1
    let preferred = Double(displayWidth) / s
    return min(range.upperBound, max(range.lowerBound, preferred))
}

/// Grab offset (press distance from the line) held for the whole drag, so
/// grabbing the strip's edge moves the divider BY the pointer instead of
/// snapping the line under the cursor on the first drag event.
func dividerLineX(originX: CGFloat, localX: CGFloat, grabOffset: CGFloat) -> CGFloat {
    originX + localX - grabOffset
}

/// Grab strip as an AppKit view owning both cursor and drag.
/// docs/architecture.md § Mouse cursor over the pane dividers.
/// Cursor arbitration starts from the deepest hit-tested view, so the strip
/// must take part in hit testing (transparent = no ↔ at all) and live inside a
/// full-size ancestor — an overhanging `NSView` in a SwiftUI branch is not
/// reliably hit-tested, hence `paneGrabStrip` attaches to the whole pane
/// container, not the 1pt line.
private final class DividerGrabView: NSView {
    /// Strip's left edge in caller's space, kept fresh by `updateNSView` —
    /// the strip moves with every resize tick.
    var originX: CGFloat = 0
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    /// SwiftUI neighbours publish no cursor, so nothing replaces ↔ on exit —
    /// hence the exit tracking. `.inVisibleRect` mirrors the cursor rect.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    /// Restore arrow only where nobody would: the cursor-owning neighbour is
    /// searched among the hit view's ANCESTORS (hitTest returns the deepest
    /// view). WKWebView deliberately NOT counted — it publishes nothing over
    /// blank regions, so counting it leaves ↔ across the whole Preview; the
    /// residual arrow-over-content case clears itself on the next move
    /// (docs/architecture.md § Mouse cursor).
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let hit = window?.contentView?.hitTest(event.locationInWindow)
        let ownsCursor = sequence(first: hit, next: { $0?.superview })
            .contains { $0 is NSTextView }
        if !ownsCursor { NSCursor.arrow.set() }
    }

    /// Press without movement is not a resize: reporting from `mouseDown`
    /// committed the click x as pane width, so clicking a row the strip
    /// overhangs nudged the pane. Press only records the grab point.
    override func mouseDown(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        grabOffset = convert(event.locationInWindow, from: nil).x - bounds.midX
    }

    /// Pointer-to-line distance at the press, held for the drag.
    private var grabOffset: CGFloat = 0

    /// Opaque strip would swallow the wheel: the pane behind is a SIBLING
    /// subtree, so the responder walk never reaches its scroll view.
    /// Re-hit-test with the strip transparent and forward.
    override func scrollWheel(with event: NSEvent) {
        passesThroughHitTest = true
        let behind = window?.contentView?.hitTest(event.locationInWindow)
        passesThroughHitTest = false
        guard let behind, behind !== self else {
            super.scrollWheel(with: event)
            return
        }
        behind.scrollWheel(with: event)
    }

    /// Only for the wheel re-hit-test; `hitTest` must return self for every
    /// other event — that is what makes the strip grabbable at all.
    private var passesThroughHitTest = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesThroughHitTest ? nil : super.hitTest(point)
    }

    override func mouseDragged(with event: NSEvent) {
        // Drag past the width clamp leaves the strip (and its cursor rect)
        // behind; hold ↔ while the mouse is down.
        NSCursor.resizeLeftRight.set()
        report(event)
    }

    private func report(_ event: NSEvent) {
        onDrag?(dividerLineX(originX: originX,
                             localX: convert(event.locationInWindow, from: nil).x,
                             grabOffset: grabOffset))
    }
}

private struct DividerGrabStrip: NSViewRepresentable {
    let originX: CGFloat
    let onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerGrabView { DividerGrabView() }

    func updateNSView(_ nsView: DividerGrabView, context: Context) {
        nsView.originX = originX
        nsView.onDrag = onDrag
    }
}

/// The 1px separator line alone. Its interactive half is `paneGrabStrip`,
/// attached to the pane CONTAINER — see `DividerGrabView` for why it cannot
/// hang off this line.
struct PaneDivider: View {
    /// Grab-strip width centred on the 1px line.
    static let grabWidth: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

extension View {
    /// Grab strip centred on the divider line at `lineX` (nil = divider off
    /// screen). The drag reports ABSOLUTE cursor x, not accumulated
    /// translation — the divider moves with the resize, so translation-based
    /// dragging feeds back on itself and flickers.
    func paneGrabStrip(lineX: CGFloat?, onDrag: @escaping (CGFloat) -> Void) -> some View {
        let width = PaneDivider.grabWidth
        return overlay(alignment: .leading) {
            if let lineX {
                DividerGrabStrip(originX: lineX - width / 2, onDrag: onDrag)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .offset(x: lineX - width / 2)
            }
        }
    }
}

struct ContentView: View {

    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?
    /// Lite windows pass false: no workspace sidebar.
    var allowsSidebar: Bool = true
    /// Main workspace window (Save As re-opens in place).
    var isMain: Bool = true
    var onSave: () -> Void = {}
    var onSaveAs: () -> Void = {}

    @AppStorage("editorMode") private var storedMode: String = EditorMode.preview.rawValue
    /// Sidebar itself + width live in `MainChrome`; this window still flips
    /// visibility (e.g. the Git chip).
    @AppStorage("sidebarVisible") private var sidebarVisible = false
    @AppStorage("sidebarTab") private var sidebarTab = "files"
    @AppStorage("inspectorVisible") private var inspectorVisible = false
    @AppStorage("inspectorWidth") private var inspectorWidth = InspectorPane.defaultWidth
    @AppStorage("inspectorTab") private var inspectorTab = "outline"
    /// Split mode: edit pane's share.
    @AppStorage("splitFraction") private var splitFraction = 0.5
    @ObservedObject private var editorSettings = EditorSettings.shared
    @ObservedObject private var workspace = WorkspaceModel.shared
    @ObservedObject private var externalChanges = ExternalChangeCenter.shared
    @ObservedObject private var lineChanges = LineChangeTracker.shared
    @State private var wordCount = 0
    @State private var charCount = 0
    @State private var formatActions: FormatActions?
    @State private var lintSummary: LintSummary?
    /// Text left edge from Source/Visual (their inset already reserves the
    /// numbers margin). Preview computes its own.
    @State private var editorTextLeading: CGFloat = 0
    @State private var showLintPopover = false
    @State private var positionStore = EditorPositionStore()
    /// Shared action strip (all modes). Ref box: rebinding closures must not
    /// trigger SwiftUI view updates.
    @State private var stripActions = EditorStripActions()
    /// Strip B/I/`/S accent state (from editor caret callbacks).
    @State private var activeFormats = ActiveInlineFormats()
    /// Epoch gate over `activeFormats` writes: drops publishes queued by an
    /// outgoing editor — see `setEditorMode`.
    @State private var formatsGate = ActiveFormatsGate()
    /// ⌘F find state for full Preview mode; driven by Edit ▸ Find (focused
    /// value) and the overlaid `PreviewFindBar`.
    @StateObject private var previewFind = PreviewFindModel()
    @State private var showExternalDiff = false
    @State private var showGitCommit = false
    @State private var gitSnapshot = GitFileSnapshot.empty
    @State private var gitRefreshTask: Task<Void, Never>?

    private static let splitFractionRange = 0.25...0.75

    private var mode: EditorMode { EditorMode(rawValue: storedMode) ?? .preview }

    /// Source/Visual look: fixed editor theme + General's base color
    /// overrides. Preview has its own `PreviewTheme`.
    private var theme: EditorTheme { editorSettings.effectiveTheme }

    private var appearanceIsDark: Bool { editorSettings.general.appearance.isDark }

    private var modeBinding: Binding<EditorMode> {
        Binding(
            get: { EditorMode(rawValue: storedMode) ?? .preview },
            set: { setEditorMode($0) }
        )
    }

    /// Edit ▸ Find bridge; published only while `mode == .preview` —
    /// Source/Visual keep the native `NSTextFinder`.
    private var previewFindActions: PreviewFindActions {
        PreviewFindActions(
            show: { previewFind.activate() },
            findNext: { previewFind.next() },
            findPrevious: { previewFind.previous() },
            useSelectionForFind: { previewFind.useSelectionForFind() }
        )
    }

    /// Switch mode after flushing coalesced typing onto the undo stack (⌘Z
    /// must survive mode switches). Only the synchronous belt lives here; the
    /// idempotent tail runs in `modeDidChange()`, which also catches writers
    /// bypassing this func (control socket).
    private func setEditorMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        document.commitContentEdit()
        // A mode must not inherit format fields the incoming editor won't
        // recompute (Source prefix-based vs Visual block-model disagree on
        // edge cases). Advance + reset must be synchronous with the write: a
        // publish already on the main queue can run before SwiftUI commits,
        // and `modeDidChange` only cleans up at the commit.
        formatsGate.advance()
        activeFormats = ActiveInlineFormats()
        storedMode = newMode.rawValue
    }

    /// Idempotent tail of a mode transition, hooked to `storedMode` so it
    /// runs for EVERY writer of the shared default — the control socket
    /// (`editmdctl mode …`) writes UserDefaults directly, bypassing
    /// `setEditorMode`.
    private func modeDidChange() {
        document.commitContentEdit()
        // The render pass advanced the gate (`noteMode`): a stale publish
        // that slipped in before the commit is wiped by this reset, one after
        // it is dropped by epoch. Coordinators force-emit their first value,
        // repopulating the strip.
        activeFormats = ActiveInlineFormats()
        // Leaving Preview retires its ⌘F find bar and highlights.
        if mode != .preview { previewFind.close() }
        if mode != .visual {
            // Row/column ops exist only on Visual's native tables. Table and
            // formula *insertion* is dual-mode: leave those closures for the
            // next mode to rebind, so Insert buttons don't go briefly dead on
            // Source↔Split switches.
            stripActions.tableAddRow = nil
            stripActions.tableDeleteRow = nil
            stripActions.tableAddColumn = nil
            stripActions.tableDeleteColumn = nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                // Workspace sidebar lives in `MainChrome` (NOT `.id`-swapped
                // per file) so its scroll/selection/filter survive file
                // switches. Here: editor + right inspector only.
                let panes = resolveSidePaneWidths(
                    available: geo.size.width,
                    sidebarWidth: 0,
                    inspectorWidth: InspectorPane.clampWidth(inspectorWidth),
                    sidebarVisible: false,
                    inspectorVisible: inspectorVisible)
                HStack(spacing: 0) {
                    editorArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if inspectorVisible {
                        PaneDivider()
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
                // Strip on this container, not the 1pt line: only here does
                // hit testing reach it on both sides of the divider.
                .paneGrabStrip(lineX: inspectorVisible ? geo.size.width - panes.inspector : nil) { x in
                    // Inspector is last: display width = divider→right edge.
                    inspectorWidth = preferredPaneWidthFromDrag(
                        displayWidth: geo.size.width - x, scale: panes.scale,
                        range: InspectorPane.widthRange)
                }
                .animation(.easeInOut(duration: 0.15), value: inspectorVisible)
            }
            statusBar
        }
        // Appearance override lives on the window root so non-editor panes
        // follow it too; sidebar toggle is provided once by `MainChrome`.
        .toolbar {
            // MainChrome owns the trailing buttons (they must exist on
            // folder/welcome branches too); lite windows have no MainChrome.
            if !isMain {
                EditorToolbar(
                    editorSettings: editorSettings,
                    appearanceIsDark: appearanceIsDark,
                    inspectorVisible: $inspectorVisible
                )
            }
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
        .onChange(of: storedMode) { modeDidChange() }
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
                // Feed Back/Forward the live caret; this view is .id-recreated
                // per file, so the closure always points at the current store.
                DocumentHistory.shared.currentOffsetProvider = { [positionStore] in
                    positionStore.markdownOffset
                }
            }
        }
        .onChange(of: fileURL) { _ in
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
        // Typing: +/− only; never re-run status/branch/ahead-behind.
        .onChange(of: document.content) { _ in
            refreshGitSnapshot(mode: .deltaOnly, delayMs: 450)
            // Keep review anchors on the live buffer (cheap String assignment;
            // recompute only while the tab is shown).
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
            // Sidecar may have been rewritten out-of-band (smotr) — pick up
            // new replies / suggestions.
            if isMain { ReviewModel.shared.reload() }
        }
        // editmdctl open/reveal → jump. The offset waits in AppState until
        // the target file is mounted here (also consumed from onAppear /
        // fileURL change) — no timers, no dropped jumps on slow opens.
        .onReceive(NotificationCenter.default.publisher(for: .editMDControlJump)) { _ in
            consumePendingControlJump()
        }
    }

    /// Deferred one runloop turn: SwiftUI must finish mounting the new file's
    /// editors before they are poked.
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

    /// Mode-specific inset aligning the strip with the reading column.
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

    /// Mirrors the Preview CSS line-number-rail numbers instead of guessing.
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

    /// Split = fixed Source pane left + Preview right; Visual is never
    /// mounted beside Preview.
    @ViewBuilder private var editorArea: some View {
        GeometryReader { geo in
            // Must precede every sink built below — see `noteMode`.
            let _ = formatsGate.noteMode(mode)
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
                                  showTableOps: mode == .visual,
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
                    // Line numbers / dirty marks are baked into the HTML
                    // (`data-ln`) so they scroll with the page — no rail to sync.
                    MarkdownPreviewView(document: document, fileURL: fileURL,
                                        positionStore: positionStore,
                                        onRequestEdit: { setEditorMode(.visual) },
                                        toolbarActions: stripActions,
                                        onActiveFormats: formatsGate.sink { activeFormats = $0 },
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
                        PaneDivider()
                        MarkdownPreviewView(document: document, fileURL: fileURL,
                                            positionStore: positionStore)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .paneGrabStrip(lineX: splitEditorWidth) { x in
                        splitFraction = min(Self.splitFractionRange.upperBound,
                                            max(Self.splitFractionRange.lowerBound,
                                                Double(x) / max(1, Double(geo.size.width))))
                    }
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
                    bindStrip(from: actions)
                },
                onActiveFormats: formatsGate.sink { activeFormats = $0 },
                onTextLeading: { editorTextLeading = $0 }
            )
        case .preview:
            // Unreachable: editorArea routes .preview to the full preview.
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
                bindStrip(from: actions)
            },
            onLintUpdate: { summary in lintSummary = summary },
            onActiveFormats: formatsGate.sink { activeFormats = $0 },
            onVisibleOffset: visibleOffset,
            onTextLeading: { editorTextLeading = $0 }
        )
    }

    /// Straight copy of every field: nil fields stay nil, so the strip
    /// inherits exactly the publisher's capabilities.
    private func bindStrip(from fa: FormatActions) {
        stripActions.toggleBold = fa.toggleBold
        stripActions.toggleItalic = fa.toggleItalic
        stripActions.toggleStrikethrough = fa.toggleStrikethrough
        stripActions.toggleCodeSpan = fa.toggleCodeSpan
        stripActions.toggleHighlight = fa.toggleHighlight
        stripActions.editLink = fa.editLink
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
        stripActions.insertTable = fa.insertTable
        stripActions.tableAddRow = fa.tableAddRow
        stripActions.tableDeleteRow = fa.tableDeleteRow
        stripActions.tableAddColumn = fa.tableAddColumn
        stripActions.tableDeleteColumn = fa.tableDeleteColumn
        stripActions.insertInlineFormula = fa.insertInlineFormula
        stripActions.insertBlockFormula = fa.insertBlockFormula
        // No objectWillChange — strip UI is mode-driven; closures are read on tap.
    }

    /// Model keeps the compose request until the Review tab appears —
    /// avoids a race when this also opens a previously hidden sidebar.
    private func requestReviewMark() {
        guard allowsSidebar, mode == .preview || mode == .split else { return }
        inspectorVisible = true
        inspectorTab = "review"
        ReviewModel.shared.requestCompose()
    }

    /// Undoable whole-document replace; rejects if the buffer changed since
    /// the diff preview was opened.
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

    // MARK: - Status bar

    private var statusBar: some View {
        // Preview has no editor callbacks — count directly from the document.
        let (words, chars) = mode == .preview
            ? wordAndCharCount(in: document.content)
            : (wordCount, charCount)
        let pluginDiagnostics = builtInPluginConfigurationDiagnosticsForStatusBar(
            mode: mode, markdown: document.content)
        return HStack(spacing: 10) {
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
            BackgroundActivityChip()
            // Grey while listening, accent once /ide attached.
            ClaudeIDEChip()
            // Info only: Commit / Push live in the Git sidebar tab.
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

    // MARK: - Lint status

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

    private func openFromSidebar(_ url: URL) {
        openFileFromWorkspaceSidebar(url, currentURL: fileURL)
    }
}

// MARK: - Shared workspace-sidebar open routing

/// Open from sidebar/inspector: if already open in another window, ask jump
/// vs. move-here; else replace the main window's file in place. Free function
/// so `MainChrome` and `ContentView` share one behaviour.
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
