import SwiftUI
import AppKit

/// App-wide delayed progress: input blocks immediately, the indicator appears
/// only after `revealDelay` (no flash for fast ops). Overlapping callers safe.
@MainActor
final class LongRunningOperationCenter: ObservableObject {
    struct Operation: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
    }

    static let shared = LongRunningOperationCenter()

    @Published private(set) var visibleOperation: Operation?
    @Published private(set) var isBlocking = false

    private let revealDelay: Duration
    private var active: [Operation] = []
    private var revealed = Set<UUID>()
    private var revealTasks: [UUID: Task<Void, Never>] = [:]

    init(revealDelay: Duration = .milliseconds(250)) {
        self.revealDelay = revealDelay
    }

    @discardableResult
    func begin(title: String) -> UUID {
        let operation = Operation(id: UUID(), title: title)
        active.append(operation)
        isBlocking = true
        revealTasks[operation.id] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: revealDelay)
            guard !Task.isCancelled,
                  active.contains(where: { $0.id == operation.id }) else { return }
            revealed.insert(operation.id)
            refreshVisibleOperation()
        }
        return operation.id
    }

    func finish(_ id: UUID) {
        revealTasks.removeValue(forKey: id)?.cancel()
        active.removeAll { $0.id == id }
        revealed.remove(id)
        isBlocking = !active.isEmpty
        refreshVisibleOperation()
    }

    func run<T>(title: String,
                operation: @MainActor () async throws -> T) async rethrows -> T {
        let id = begin(title: title)
        defer { finish(id) }
        return try await operation()
    }

    private func refreshVisibleOperation() {
        visibleOperation = active.last { revealed.contains($0.id) }
    }
}

private struct LongRunningOperationOverlayModifier: ViewModifier {
    @ObservedObject private var operations = LongRunningOperationCenter.shared

    func body(content: Content) -> some View {
        ZStack {
            content
                .allowsHitTesting(!operations.isBlocking)

            if let operation = operations.visibleOperation {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .transition(.opacity)

                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(operation.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(operation.title)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: operations.visibleOperation?.id)
    }
}

extension View {
    func longRunningOperationOverlay() -> some View {
        modifier(LongRunningOperationOverlayModifier())
    }
}

enum EditorOpenReason: Sendable {
    case existing
    case created
    case finder
}

/// In-app navigation keeps the mode; create → Visual (write-first),
/// Finder/Dock → Preview (read-first).
func editorModeOverride(for reason: EditorOpenReason) -> EditorMode? {
    switch reason {
    case .existing: return nil
    case .created: return .visual
    case .finder: return .preview
    }
}

/// Raw cold-launch reset: editor mode is session-sticky
/// (`@AppStorage("editorMode")`) but must NOT survive relaunch — cold launch
/// starts in Preview. Also drops the orphaned `editorMode.byPath` key of the
/// removed EditorModeStore (hygiene only, nothing reads it).
/// Gated by `AppState.applyColdLaunchEditorMode()`: an `editmd://` launch
/// delivers its open BEFORE `applicationDidFinishLaunching`, so the reset must
/// stand aside for a mode that open picked or reserved. Free function for
/// testing against injected `UserDefaults`.
func resetEditorModeForColdLaunch(_ defaults: UserDefaults) {
    defaults.set(EditorMode.preview.rawValue, forKey: "editorMode")
    defaults.removeObject(forKey: "editorMode.byPath")
}

/// Pure queue behind `AppState`'s fs-mutation routing gate; keeps the
/// suspend/replay contract deterministic and testable without app windows.
struct PathMutationRouteQueue {
    enum Destination: Equatable, Sendable {
        case main
        case separate
    }

    struct Route: Equatable, Sendable {
        var url: URL
        let destination: Destination
    }

    private var roots: [UUID: URL] = [:]
    private var deferred: [Route] = []

    mutating func begin(at root: URL) -> UUID {
        let id = UUID()
        roots[id] = root.standardizedFileURL
        return id
    }

    mutating func enqueueIfBlocked(
        _ url: URL,
        destination: Destination,
        ignoring ignoredMutationIDs: Set<UUID> = []
    ) -> Bool {
        let standardized = url.standardizedFileURL
        guard isBlocked(standardized, ignoring: ignoredMutationIDs) else {
            return false
        }
        deferred.append(Route(url: standardized, destination: destination))
        return true
    }

    func isBlocked(
        _ url: URL,
        ignoring ignoredMutationIDs: Set<UUID> = []
    ) -> Bool {
        let standardized = url.standardizedFileURL
        return roots.contains(where: { id, root in
            !ignoredMutationIDs.contains(id)
                && Self.isPath(standardized, inside: root)
        })
    }

    func roots(for ids: Set<UUID>) -> [URL] {
        ids.compactMap { roots[$0] }
    }

    mutating func relocate(from oldRoot: URL, to newRoot: URL) {
        deferred = deferred.map { route in
            var relocated = route
            relocated.url = WorkspaceModel.relocatedURL(
                route.url, from: oldRoot, to: newRoot)
            return relocated
        }
        roots = roots.mapValues {
            WorkspaceModel.relocatedURL($0, from: oldRoot, to: newRoot)
        }
    }

    mutating func finish(_ id: UUID, discardingRoutes: Bool = false) -> [Route] {
        finish(
            [id],
            discardingRouteIDs: discardingRoutes ? [id] : [])
    }

    /// Releases one transaction's roots atomically. Deferred opens retain
    /// their original global order; a later route never jumps ahead of an
    /// earlier route that is still covered by another mutation.
    mutating func finish(
        _ ids: Set<UUID>,
        discardingRouteIDs: Set<UUID> = []
    ) -> [Route] {
        var discardedRoots: [URL] = []
        for id in ids {
            guard let root = roots.removeValue(forKey: id) else { continue }
            if discardingRouteIDs.contains(id) {
                discardedRoots.append(root)
            }
        }
        if !discardedRoots.isEmpty {
            deferred.removeAll { route in
                discardedRoots.contains(where: {
                    Self.isPath(route.url, inside: $0)
                })
            }
        }

        let readyCount = deferred.prefix { route in
            !roots.values.contains(where: {
                Self.isPath(route.url, inside: $0)
            })
        }.count
        let ready = Array(deferred.prefix(readyCount))
        deferred.removeFirst(readyCount)
        return ready
    }

    static func isPath(_ url: URL, inside root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

/// App-wide window routing. Main window = single `Window` scene showing
/// `currentURL` (file editor or folder card); opening in place is a mutation of
/// that property. Lite windows = value-based `WindowGroup` (files only).
///
/// SwiftUI window actions exist only inside a live scene, so the main view
/// hands them here on appear; AppKit callers (Finder-open handler, menu
/// commands) drive windows through this object. Opens arriving before a scene
/// is alive are buffered.
@MainActor
final class AppState: ObservableObject {

    struct FilePresentationState: Equatable, Sendable {
        enum Focus: Equatable, Sendable { case main, separate, neither }
        let wasInMain: Bool
        let hadSeparateWindow: Bool
        let focus: Focus
    }

    static let shared = AppState()

    /// Active path of the main window.
    /// - file URL → editor
    /// - directory URL → folder info card
    /// - `nil` + `isUntitled == false` → welcome home
    /// - `nil` + `isUntitled == true` → empty scratch (File ▸ New)
    @Published var currentURL: URL?

    /// When `currentURL` is `nil`, distinguishes welcome home from an untitled
    /// scratch document. Cold launch starts on welcome (`false`).
    @Published var isUntitled: Bool = false

    private var openWindow: OpenWindowAction?
    private var pendingSeparateURLs: [URL] = []
    private var pathMutationRoutes = PathMutationRouteQueue()
    private weak var mainWindow: NSWindow?
    private let defaults: UserDefaults

    /// Pending control-channel jump (url + UTF-16 offset), consumed once the
    /// target mounts — a fixed-delay notification dropped jumps on slow opens.
    private var pendingControlJump: (url: URL, offset: Int)?

    /// True once an open picked this launch's editor mode. An open arriving
    /// before `applicationDidFinishLaunching` (launch-by-URL) must not be
    /// overruled by the cold-launch reset.
    private(set) var didApplyEditorModeOverride = false

    /// In-flight creates that will pick the mode when they land (a clip writes
    /// off-main). They hold off the cold-launch reset WITHOUT writing
    /// `editorMode`: the setting is global, so writing Visual up front would
    /// yank the current document into Visual — and strand it there on a failed
    /// write.
    private var pendingCreatedModeClaims = 0

    /// Set when the cold-launch reset stood aside for a reservation; it is
    /// replayed if that create never lands.
    private var coldLaunchResetDeferred = false

    /// An open picked the mode, or an in-flight create reserved the right.
    /// Launch-time work must not steal a window someone else is filling.
    var hasEditorModeClaim: Bool {
        didApplyEditorModeOverride || pendingCreatedModeClaims > 0
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Control-channel jump

    /// Caret/scroll jump: consumed immediately when the target is mounted,
    /// else by ContentView on mount (onAppear / fileURL change).
    func requestControlJump(url: URL, offset: Int) {
        pendingControlJump = (url.standardizedFileURL, offset)
        NotificationCenter.default.post(name: .editMDControlJump, object: nil)
    }

    /// Returns the pending offset if it targets `url`, clearing it.
    func consumeControlJump(for url: URL?) -> Int? {
        guard let url, let pending = pendingControlJump,
              pending.url == url.standardizedFileURL else { return nil }
        pendingControlJump = nil
        return pending.offset
    }

    // MARK: Back/Forward

    /// Gates the mouse side buttons: a click from a detached lite window must
    /// not spin the main window's history.
    var mainWindowIsKey: Bool { mainWindow?.isKeyWindow == true }

    /// View ▸ Back / mouse "back". No-op at the start of history.
    func historyBack() {
        DocumentHistory.shared.goBack { navigateToHistory($0) }
    }

    /// View ▸ Forward / mouse "forward". No-op at the tip.
    func historyForward() {
        DocumentHistory.shared.goForward { navigateToHistory($0) }
    }

    /// Always the main window — Back/Forward is that window's own trail, so a
    /// target open in a lite window is still brought back in place (the lite
    /// window's non-main editor would drop the caret restore). Restore rides
    /// the control-jump path; `openInMainWindow` re-records the same URL as a
    /// no-op because `DocumentHistory` already moved its index onto it.
    private func navigateToHistory(_ visit: DocumentHistory.Visit) {
        requestControlJump(url: visit.url, offset: visit.offset)
        openInMainWindow(visit.url)
    }

    /// Main pane is the app welcome (not a document / folder).
    var isWelcome: Bool { currentURL == nil && !isUntitled }

    // MARK: Scene wiring

    /// Main window's `onAppear`: capture the window action, flush buffered opens.
    func bindOpenWindow(_ action: OpenWindowAction) {
        openWindow = action
        let pending = pendingSeparateURLs
        pendingSeparateURLs.removeAll()
        // Re-enter the ordinary route so a path-mutation gate installed while
        // the scene was unavailable can defer/relocate this URL too.
        for url in pending { openInSeparateWindow(url) }
    }

    func bindMainWindow(_ window: NSWindow) {
        mainWindow = window
    }

    // MARK: Routing

    /// Finder open, routed per Lite-mode setting. Starts in Preview
    /// (read-first); later mode switches persist for in-app opens.
    func handleOpen(_ url: URL) {
        applyEditorModeOverride(for: .finder)
        // Finder delivers only files/packages; folders come from the sidebar.
        if EditorSettings.shared.general.liteMode {
            openInSeparateWindow(url)
        } else {
            openInMainWindow(url)
        }
    }

    /// Welcome home screen in the main window (cold-start default).
    func showWelcome() {
        isUntitled = false
        currentURL = nil
        openWindow?(id: WindowID.main)
    }

    /// Empty untitled markdown in the main window (File ▸ New).
    func openUntitled() {
        applyEditorModeOverride(for: .created)
        isUntitled = true
        currentURL = nil
        openWindow?(id: WindowID.main)
    }

    /// Open a file EditMD just created — starts in write-first Visual.
    func openCreatedFile(_ url: URL) {
        applyEditorModeOverride(for: .created)
        openInMainWindow(url)
    }

    /// Loads `url` into the main window, bringing it to the front.
    /// Directories open the folder info card; files open the editor.
    /// Pass `nil` only to return to welcome — prefer `openUntitled()` for New.
    func openInMainWindow(_ url: URL?) {
        openInMainWindow(url, ignoringPathMutationIDs: [])
    }

    private func openInMainWindow(
        _ url: URL?,
        ignoringPathMutationIDs mutationIDs: Set<UUID>
    ) {
        let std = url?.standardizedFileURL
        if let std {
            guard !pathMutationRoutes.enqueueIfBlocked(
                std, destination: .main, ignoring: mutationIDs
            ) else {
                return
            }
            isUntitled = false
            currentURL = std
            if !Self.isFolder(std) {
                WorkspaceModel.shared.noteOpened(std)
            }
            // The branch the next launch reopens (the sidebar collapses the rest).
            WorkspaceModel.shared.noteActive(std)
            DocumentHistory.shared.recordVisit(std)
        } else {
            // Explicit nil → welcome, not a scratch (New = `openUntitled()`).
            isUntitled = false
            currentURL = nil
        }
        openWindow?(id: WindowID.main)
    }

    /// Sidebar-less lite window. Buffered until a scene hands over the action;
    /// folders rejected (no lite folder UI).
    func openInSeparateWindow(_ url: URL) {
        openInSeparateWindow(url, ignoringPathMutationIDs: [])
    }

    private func openInSeparateWindow(
        _ url: URL,
        ignoringPathMutationIDs mutationIDs: Set<UUID>
    ) {
        let std = url.standardizedFileURL
        guard !Self.isFolder(std) else { return }
        guard !pathMutationRoutes.enqueueIfBlocked(
            std, destination: .separate, ignoring: mutationIDs
        ) else {
            return
        }
        if let openWindow {
            openWindow(value: std)
        } else {
            pendingSeparateURLs.append(std)
        }
    }

    /// Keeps main-window routing and not-yet-mounted routes valid after a root
    /// folder moves to a new path on disk.
    func relocateFolder(from oldRoot: URL, to newRoot: URL) {
        if let currentURL {
            self.currentURL = WorkspaceModel.relocatedURL(
                currentURL, from: oldRoot, to: newRoot)
        }
        pendingSeparateURLs = pendingSeparateURLs.map {
            WorkspaceModel.relocatedURL($0, from: oldRoot, to: newRoot)
        }
        pathMutationRoutes.relocate(from: oldRoot, to: newRoot)
        if let pendingControlJump {
            self.pendingControlJump = (
                WorkspaceModel.relocatedURL(
                    pendingControlJump.url, from: oldRoot, to: newRoot),
                pendingControlJump.offset)
        }
    }

    /// Defers every route into `url` while detached fs work runs — closes the
    /// reentrancy window where a Finder/control open could create a URL-bound
    /// registry entry between preflight and the item reaching its destination.
    @discardableResult
    func beginPathMutation(at url: URL) -> UUID {
        pathMutationRoutes.begin(at: url)
    }

    func isPathMutationInProgress(at url: URL) -> Bool {
        pathMutationRoutes.isBlocked(url)
    }

    /// Releases routes buffered by `beginPathMutation`. On success call
    /// `relocateFile`/`relocateFolder` FIRST so queued URLs follow the
    /// destination; on failure they replay at their original paths.
    func finishPathMutation(_ id: UUID) {
        replay(pathMutationRoutes.finish(id))
    }

    /// Drops opens aimed at a path whose rollback left no unambiguous file —
    /// replaying would open a duplicate source or create at a dead path.
    func discardPathMutation(_ id: UUID) {
        finishPathMutations([id], discardingRouteIDs: [id])
    }

    /// Releases all gates of one fs transaction in one step so deferred window
    /// routes replay in user-request order.
    func finishPathMutations(
        _ ids: Set<UUID>,
        discardingRouteIDs: Set<UUID> = []
    ) {
        let droppedRoots = pathMutationRoutes.roots(for: discardingRouteIDs)
        discardPathState(inside: droppedRoots)
        replay(pathMutationRoutes.finish(
            ids,
            discardingRouteIDs: discardingRouteIDs))
    }

    /// Drops navigation state under roots whose files no longer exist
    /// (discarded move destinations, trashed folders): main window → Welcome
    /// when it pointed inside; DocumentHistory pruned.
    func discardPathState(inside roots: [URL]) {
        guard !roots.isEmpty else { return }
        let isDropped: (URL) -> Bool = { url in
            roots.contains { PathMutationRouteQueue.isPath(url, inside: $0) }
        }
        pendingSeparateURLs.removeAll(where: isDropped)
        if let pendingControlJump, isDropped(pendingControlJump.url) {
            self.pendingControlJump = nil
        }
        if let currentURL, isDropped(currentURL) {
            openInMainWindow(nil)
        }
        DocumentHistory.shared.discardPaths(inside: roots)
    }

    private func replay(_ routes: [PathMutationRouteQueue.Route]) {
        for route in routes {
            switch route.destination {
            case .main:
                openInMainWindow(route.url)
            case .separate:
                openInSeparateWindow(route.url)
            }
        }
    }

    /// Capture + close every presentation of a file before its path moves.
    /// Main window (singleton) parks on Welcome; lite windows close and are
    /// recreated at the destination URL.
    func detachFileForMove(_ url: URL) -> FilePresentationState {
        let source = url.standardizedFileURL
        let wasInMain = currentURL?.standardizedFileURL == source
        let separateWindows = NSApp.windows.filter { window in
            window !== mainWindow
                && window.representedURL?.standardizedFileURL == source
        }
        let focus: FilePresentationState.Focus
        if wasInMain, mainWindow?.isKeyWindow == true {
            focus = .main
        } else if separateWindows.contains(where: \.isKeyWindow) {
            focus = .separate
        } else {
            focus = .neither
        }

        if wasInMain {
            isUntitled = false
            currentURL = nil
        }
        separateWindows.forEach { $0.close() }
        return FilePresentationState(
            wasInMain: wasInMain,
            hadSeparateWindow: !separateWindows.isEmpty,
            focus: focus)
    }

    /// Restores the main/lite topology after a move (or at the old URL after
    /// rollback); the previously focused kind reopens last.
    func restoreFilePresentation(
        _ state: FilePresentationState,
        at url: URL,
        ignoringPathMutationIDs mutationIDs: Set<UUID> = []
    ) {
        switch state.focus {
        case .separate:
            if state.wasInMain {
                openInMainWindow(url, ignoringPathMutationIDs: mutationIDs)
            }
            if state.hadSeparateWindow {
                openInSeparateWindow(url, ignoringPathMutationIDs: mutationIDs)
            }
        case .main:
            if state.hadSeparateWindow {
                openInSeparateWindow(url, ignoringPathMutationIDs: mutationIDs)
            }
            if state.wasInMain {
                openInMainWindow(url, ignoringPathMutationIDs: mutationIDs)
            }
        case .neither:
            if state.wasInMain {
                openInMainWindow(url, ignoringPathMutationIDs: mutationIDs)
            }
            if state.hadSeparateWindow {
                openInSeparateWindow(url, ignoringPathMutationIDs: mutationIDs)
            }
        }
    }

    /// Keeps pending routes coherent after a file moves.
    func relocateFile(from oldURL: URL, to newURL: URL) {
        let old = oldURL.standardizedFileURL
        let new = newURL.standardizedFileURL
        if currentURL?.standardizedFileURL == old { currentURL = new }
        pendingSeparateURLs = pendingSeparateURLs.map {
            $0.standardizedFileURL == old ? new : $0
        }
        pathMutationRoutes.relocate(from: old, to: new)
        if let pendingControlJump, pendingControlJump.url.standardizedFileURL == old {
            self.pendingControlJump = (new, pendingControlJump.offset)
        }
    }

    // MARK: URL scheme (`editmd://`)

    /// `editmd://` entry (running app and cold launch). Untrusted — any web
    /// page can open it, so this path only ever CREATES a file; never
    /// overwrites, deletes, or interprets the body
    /// (docs/integration.md § URL scheme).
    func handleURLCommand(_ url: URL) {
        guard let command = EditMDURLCommand.parse(url) else {
            // Log the command word only: the query carries the title and (via
            // reserved `content=`) the body — must not land in the unified log.
            urlSchemeLog.notice(
                "ignored editmd:// command \(url.host ?? "(none)", privacy: .public)")
            return
        }
        switch command {
        case .newClip(let clip):
            createClip(clip)
        }
    }

    /// `editmd://new` — pasteboard → new file, then open it.
    /// Main actor: pasteboard read + workspace lookup only; folder create and
    /// the (up to a few MB) write run off it — a slow/network vault must not
    /// freeze the UI from a URL any page can open. Across that suspension the
    /// editor mode is only *reserved*: Visual is written by `openCreatedFile`
    /// once the file exists; a failed write leaves the mode untouched.
    private func createClip(_ clip: EditMDURLCommand.NewClip) {
        let body = clip.usesClipboard
            ? (NSPasteboard.general.string(forType: .string) ?? "")
            : ""
        let destination = Self.clipDestination(for: clip)
        reserveEditorModeForCreate()
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let folder: URL
                    switch destination.resolved(isExistingFolder: Self.isFolder) {
                    case .folder(let chosen):
                        folder = chosen
                    case .starterFolder:
                        // Seeding may be racing (or not started yet on a
                        // launch-by-clip): one owner answers both.
                        folder = try await StarterFolderOwner.shared.folder()
                    }
                    return try ClipFile.write(body, baseName: clip.name, in: folder)
                }.value
                WorkspaceModel.shared.noteFilesystemChange()
                urlSchemeLog.info(
                    "created clip \(url.lastPathComponent, privacy: .private)")
                // Handoff comes from a browser window; without this the file
                // opens behind it when EditMD was already running.
                NSApp.activate()
                openCreatedFile(url)
                endEditorModeReservation()
            } catch {
                // The message embeds the destination path — user data.
                urlSchemeLog.error(
                    "clip write failed: \(error.localizedDescription, privacy: .private)")
                endEditorModeReservation()
                presentFolderError(error,
                                   title: String(localized: "Could not save the clip"))
            }
        }
    }

    /// Collects destination inputs (Web clips setting, adopted roots) on the
    /// main actor; the decision and the validating stat run off it (`createClip`).
    static func clipDestination(
        for clip: EditMDURLCommand.NewClip,
        settings: EditorSettings = .shared,
        workspace: WorkspaceModel = .shared
    ) -> ClipDestination {
        ClipDestination(
            requestedWorkspace: clip.requestedWorkspace,
            mode: settings.general.clipDestination,
            configuredFolder: ClipDestination.configuredFolder(
                forSettingsPath: settings.general.clipsFolderPath),
            workspaces: workspace.workspaces.map {
                ClipDestination.AdoptedWorkspace(name: $0.name, root: $0.url)
            },
            activeWorkspaceRoot: workspace.activeWorkspaceRoot)
    }

    /// Editable documents live in DocumentRegistry; PDFs/images bypass it but
    /// still expose representedURL on their window.
    static func openDocumentURLsForDiskMutation() -> [URL] {
        let representedFiles = NSApp.windows.compactMap(\.representedURL).filter {
            !isFolder($0)
        }
        return Array(Set(DocumentRegistry.shared.openURLs + representedFiles))
    }

    /// Real on-disk directory that is not a package (`.textbundle` = document).
    nonisolated static func isFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        return !isPackage
    }

    private func applyEditorModeOverride(for reason: EditorOpenReason) {
        guard let mode = editorModeOverride(for: reason) else { return }
        // Same key as ContentView's `@AppStorage("editorMode")`.
        defaults.set(mode.rawValue, forKey: "editorMode")
        didApplyEditorModeOverride = true
        // Mode settled; nothing left for the reset to replay.
        coldLaunchResetDeferred = false
    }

    // MARK: Cold-launch editor mode

    /// From `applicationDidFinishLaunching`. Cold launch → Preview, unless an
    /// open picked the mode or an in-flight create reserved it; a reservation
    /// that never lands replays this reset instead.
    func applyColdLaunchEditorMode() {
        guard !hasEditorModeClaim else {
            coldLaunchResetDeferred = pendingCreatedModeClaims > 0
            return
        }
        resetEditorModeForColdLaunch(defaults)
    }

    /// Reserves only the *right* to pick the mode for an unfinished create;
    /// the mode itself is applied by `openCreatedFile` once the file exists.
    func reserveEditorModeForCreate() {
        pendingCreatedModeClaims += 1
    }

    /// Balances `reserveEditorModeForCreate`. If no create picked a mode and
    /// the reset stood aside for this reservation, run it now (launch still
    /// ends in Preview).
    func endEditorModeReservation() {
        pendingCreatedModeClaims = max(0, pendingCreatedModeClaims - 1)
        guard pendingCreatedModeClaims == 0,
              !didApplyEditorModeOverride,
              coldLaunchResetDeferred else { return }
        coldLaunchResetDeferred = false
        resetEditorModeForColdLaunch(defaults)
    }

}

enum WindowID {
    static let main = "main"
}
