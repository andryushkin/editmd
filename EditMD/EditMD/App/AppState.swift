import SwiftUI
import AppKit

/// App-wide delayed progress state for operations that may outlive an
/// interaction frame. Work starts (and input is blocked) immediately, while
/// the visual indicator appears only after a short delay to avoid flashing for
/// fast operations. Multiple callers can overlap safely.
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

/// Existing in-app navigation preserves the user's current mode. Creation and
/// Finder/Dock opens have explicit read/write-first defaults.
func editorModeOverride(for reason: EditorOpenReason) -> EditorMode? {
    switch reason {
    case .existing: return nil
    case .created: return .visual
    case .finder: return .preview
    }
}

/// Pure queue behind `AppState`'s filesystem-mutation routing gate. Keeping the path
/// bookkeeping separate makes the suspension/replay contract deterministic
/// and testable without opening real app windows.
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

/// App-wide window routing state (Phase 2 of the move off DocumentGroup).
///
/// The MAIN workspace window is a single `Window` scene that shows whatever
/// `currentURL` points at — a markdown file (editor) or a directory (folder
/// info card). Opening "in place" is just a mutation of this property.
/// Separate (lite) windows are value-based `WindowGroup` windows opened via
/// the captured `openWindow` action (files only).
///
/// SwiftUI's `openWindow`/`Window` actions only exist inside a live scene, so
/// the main window view hands them here on appear; AppKit-side callers (the
/// `AppDelegate` Finder-open handler, menu commands) then drive windows through
/// this object. Opens that arrive before a scene is alive are buffered.
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

    /// Pending control-channel jump (url + UTF-16 markdown offset), consumed
    /// by the main window once the target file is mounted. Replaces the old
    /// fixed-delay notification, which silently dropped the jump whenever the
    /// file took longer than the timer to open.
    private var pendingControlJump: (url: URL, offset: Int)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Control-channel jump

    /// Control channel requests a caret/scroll jump. If the target is already
    /// mounted, the notification handler consumes it immediately; otherwise
    /// ContentView consumes it on mount (onAppear / fileURL change).
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

    /// Main pane is the app welcome (not a document / folder).
    var isWelcome: Bool { currentURL == nil && !isUntitled }

    // MARK: Scene wiring

    /// Called from the main window's `onAppear` — captures the environment's
    /// window action and flushes anything that wanted a window before now.
    func bindOpenWindow(_ action: OpenWindowAction) {
        openWindow = action
        let pending = pendingSeparateURLs
        pendingSeparateURLs.removeAll()
        // Re-enter the ordinary route so a path-mutation gate installed while
        // the scene was unavailable can defer and relocate this URL too.
        for url in pending { openInSeparateWindow(url) }
    }

    func bindMainWindow(_ window: NSWindow) {
        mainWindow = window
    }

    // MARK: Routing

    /// Routes a file opened from Finder per the Lite-mode setting.
    /// Always starts in Preview — Finder/Dock opens are read-first; mode
    /// switches still persist for subsequent in-app opens (sidebar, wiki, etc.).
    func handleOpen(_ url: URL) {
        applyEditorModeOverride(for: .finder)
        // Finder only delivers files (and packages); folders come from the sidebar.
        if EditorSettings.shared.general.liteMode {
            openInSeparateWindow(url)
        } else {
            openInMainWindow(url)
        }
    }

    /// Shows the welcome home screen in the main window (cold-start default;
    /// also reachable via View ▸ Welcome when we add it later).
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

    /// Opens a file that EditMD has just created. New documents start in the
    /// write-first Visual mode; ordinary navigation keeps the selected mode.
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
            // Explicit nil → welcome (not a scratch). Callers that want New
            // use `openUntitled()`.
            isUntitled = false
            currentURL = nil
        }
        openWindow?(id: WindowID.main)
    }

    /// Opens `url` in its own sidebar-less window. Buffered if no scene has
    /// handed us the action yet. Folders are rejected (no lite folder UI).
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

    /// Defers every route into `url` while detached filesystem work is
    /// suspended. This closes the reentrancy window where Finder/control
    /// opens could create a URL-bound registry entry after preflight but
    /// before a file or folder reaches its destination.
    @discardableResult
    func beginPathMutation(at url: URL) -> UUID {
        pathMutationRoutes.begin(at: url)
    }

    func isPathMutationInProgress(at url: URL) -> Bool {
        pathMutationRoutes.isBlocked(url)
    }

    /// Releases routes buffered by `beginPathMutation`. Call the matching
    /// `relocateFile`/`relocateFolder` first on success so queued URLs follow
    /// the destination; on failure they replay at their original paths.
    func finishPathMutation(_ id: UUID) {
        replay(pathMutationRoutes.finish(id))
    }

    /// Drops opens aimed at a path whose rollback left no unambiguous file.
    /// Replaying such a route would either open a duplicate source or create a
    /// new document at a path that no longer exists.
    func discardPathMutation(_ id: UUID) {
        finishPathMutations([id], discardingRouteIDs: [id])
    }

    /// Releases every source/destination gate of one filesystem transaction
    /// in one step so deferred window routes replay in user-request order.
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

    private func discardPathState(inside roots: [URL]) {
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

    /// Captures and closes every presentation of a file before its path moves.
    /// The singleton main window stays alive on Welcome; value-based lite
    /// windows close and are recreated with the destination URL.
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

    /// Restores the same main/lite presentation topology after a move (or at
    /// the old URL after rollback), reopening the previously focused kind last.
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

    /// Editable documents live in DocumentRegistry; PDFs and images bypass it
    /// but still expose representedURL on their AppKit window.
    static func openDocumentURLsForDiskMutation() -> [URL] {
        let representedFiles = NSApp.windows.compactMap(\.representedURL).filter {
            !isFolder($0)
        }
        return Array(Set(DocumentRegistry.shared.openURLs + representedFiles))
    }

    /// True for a real directory on disk that is not a package (`.textbundle`
    /// is a document, not a folder panel target).
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
    }

}

enum WindowID {
    static let main = "main"
}
