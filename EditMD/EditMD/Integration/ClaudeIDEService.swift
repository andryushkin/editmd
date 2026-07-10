import Combine
import Foundation
import SwiftUI

// Lifecycle owner of the IDE channel (v36): starts/stops the WebSocket server,
// keeps `~/.claude/ide/<port>.lock` truthful, and publishes the connection
// state the toolbar chip renders.
//
// Main-actor, but every disk / network touch is delegated: the server is an
// actor, and lock-file IO runs in `Task.detached`.

@MainActor
final class ClaudeIDEService: ObservableObject {

    static let shared = ClaudeIDEService()

    enum State: Equatable {
        case off
        case starting
        /// Server bound, no client attached.
        case listening(port: UInt16)
        /// At least one `claude` process attached via `/ide`.
        case connected(port: UInt16, clients: Int)
        case failed(String)

        var port: UInt16? {
            switch self {
            case .listening(let port): return port
            case .connected(let port, _): return port
            default: return nil
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .off

    var isConnected: Bool { state.isConnected }

    private let server = ClaudeIDEServer()
    /// Injectable so tests never write into the user's real `~/.claude/ide`.
    private let lockDirectory: URL
    private var authToken: String?
    private var lockedPort: UInt16?
    private var advertisedFolders: [String] = []
    private var cancellables: Set<AnyCancellable> = []

    /// Start/stop epoch: every transition bumps it, and the async start body
    /// re-checks after each await — a stop (or restart) issued mid-start wins
    /// over the stale continuation instead of racing it.
    private var generation = 0

    init(lockDirectory: URL = IDELockFile.defaultDirectory) {
        self.lockDirectory = lockDirectory
    }

    // MARK: Wiring

    /// Called once from `AppDelegate`. Applies the setting now and follows it
    /// afterwards; also keeps the lock file's `workspaceFolders` current.
    func activate() {
        EditorSettings.shared.$general
            .map(\.claudeIDEEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in
                    if enabled { self?.start() } else { self?.stop() }
                }
            }
            .store(in: &cancellables)

        WorkspaceModel.shared.$workspaces
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshWorkspaceFolders() }
            }
            .store(in: &cancellables)

        AppState.shared.$currentURL
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshWorkspaceFolders() }
            }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    func start() {
        guard case .off = state else { return }
        generation += 1
        let gen = generation
        state = .starting
        let directory = lockDirectory
        let folders = claudeIDEWorkspaceFolders().map(\.path)

        Task {
            do {
                // Someone else's crashed lock file makes `/ide` dial a dead port.
                await Task.detached { _ = IDELockFile.cleanStale(in: directory) }.value
                guard generation == gen else { return }

                let token = try IDELockFile.generateAuthToken()
                let router = ClaudeIDERouter(tools: ClaudeIDETools(context: LiveEditorContext()))
                let port = try await server.start(
                    authToken: token,
                    handler: { request in await router.handle(request) },
                    onClientCountChange: { count in
                        Task { @MainActor in ClaudeIDEService.shared.clientCountChanged(count) }
                    },
                    onFailure: { message in
                        Task { @MainActor in
                            ClaudeIDEService.shared.serverFailed(message, generation: gen)
                        }
                    })
                guard generation == gen else {
                    await server.stop()
                    return
                }

                // Record the port BEFORE publishing the lock file: a client that
                // connects the instant the file appears must find `lockedPort`
                // set, or `clientCountChanged` drops the transition.
                authToken = token
                lockedPort = port
                advertisedFolders = folders
                state = .listening(port: port)

                let contents = IDELockFileContents(workspaceFolders: folders, authToken: token)
                try await Task.detached {
                    _ = try IDELockFile.write(contents, port: port, in: directory)
                }.value
                guard generation == gen else {
                    // Stopped while the file was in flight — don't leave it.
                    await Task.detached { IDELockFile.remove(port: port, in: directory) }.value
                    return
                }
            } catch {
                claudeIDELog.error("Start failed: \(String(describing: error), privacy: .public)")
                await server.stop()
                guard generation == gen else { return }
                clearSession()
                state = .failed(String(describing: error))
            }
        }
    }

    func stop() {
        guard state != .off else { return }
        generation += 1
        // Nobody will read the answer, but the continuations must not leak.
        DiffApprovalController.shared.rejectAll(reason: "integration stopped")
        let port = lockedPort
        let directory = lockDirectory
        clearSession()
        state = .off
        Task {
            await server.stop()
            if let port {
                await Task.detached { IDELockFile.remove(port: port, in: directory) }.value
            }
        }
    }

    /// App termination: the lock file must be gone before we exit, so this one
    /// call does the removal synchronously.
    func stopBeforeTerminate() {
        generation += 1
        DiffApprovalController.shared.rejectAll(reason: "app terminating")
        if let port = lockedPort {
            IDELockFile.remove(port: port, in: lockDirectory)
        }
        clearSession()
        state = .off
    }

    /// The server tore itself down (listener failed after start). Mirrors
    /// `stop()` — same session cleanup — but lands in `.failed` so the chip
    /// says why `/ide` stopped finding us.
    private func serverFailed(_ message: String, generation failedGeneration: Int) {
        guard generation == failedGeneration else { return }
        generation += 1
        DiffApprovalController.shared.rejectAll(reason: "server failed")
        let port = lockedPort
        let directory = lockDirectory
        clearSession()
        state = .failed(message)
        guard let port else { return }
        Task.detached { IDELockFile.remove(port: port, in: directory) }
    }

    /// The one place session identity is dropped. `stop`, `stopBeforeTerminate`,
    /// `serverFailed` and the start-failure path must all clear the same fields,
    /// or `refreshWorkspaceFolders` resurrects a lock file for a dead server.
    private func clearSession() {
        authToken = nil
        lockedPort = nil
        advertisedFolders = []
    }

    private func clientCountChanged(_ count: Int) {
        guard let port = state.port ?? lockedPort else { return }
        if count > 0 {
            state = .connected(port: port, clients: count)
        } else {
            // Last client left mid-diff: release the blocked `openDiff` calls.
            DiffApprovalController.shared.rejectAll(reason: "client disconnected")
            if case .off = state { return }
            state = .listening(port: port)
        }
    }

    // MARK: Workspace folders

    /// The CLI matches its cwd against `workspaceFolders` at `/ide` time.
    /// Rewrite the file in place (same port, same token) when the set changes —
    /// a live connection survives it (verified by hand, see HISTORY v36).
    func refreshWorkspaceFolders() {
        guard let port = lockedPort, let token = authToken else { return }
        let folders = claudeIDEWorkspaceFolders().map(\.path)
        guard folders != advertisedFolders else { return }
        advertisedFolders = folders
        let directory = lockDirectory
        let contents = IDELockFileContents(workspaceFolders: folders, authToken: token)
        Task.detached {
            do {
                _ = try IDELockFile.write(contents, port: port, in: directory)
            } catch {
                claudeIDELog.error("Lock rewrite failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Notifications IDE → Claude

    func notifySelectionChanged(_ selection: IDESelection) {
        guard isConnected else { return }
        let params = JSONValue.object([
            "text": .string(selection.text),
            "filePath": .string(selection.filePath),
            "fileUrl": .string(selection.fileURL),
            "selection": .object([
                "start": .object(["line": .int(selection.range.start.line),
                                  "character": .int(selection.range.start.character)]),
                "end": .object(["line": .int(selection.range.end.line),
                                "character": .int(selection.range.end.character)]),
                "isEmpty": .bool(selection.range.isEmpty),
            ]),
        ])
        Task { await server.broadcast(method: "selection_changed", params: params) }
    }

    func notifyAtMentioned(filePath: String, lineStart: Int, lineEnd: Int) {
        guard isConnected else { return }
        let params = JSONValue.object([
            "filePath": .string(filePath),
            "lineStart": .int(lineStart),
            "lineEnd": .int(lineEnd),
        ])
        Task { await server.broadcast(method: "at_mentioned", params: params) }
    }
}
