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

    /// Identity of a running server. Living inside the `State` cases, it is
    /// dropped atomically with the state transition — no separate fields to
    /// forget on a teardown path (the v36.1 lock-file-resurrection bug class).
    struct Session: Equatable, Sendable {
        let port: UInt16
        let token: String
        var folders: [String]
    }

    enum State: Equatable {
        case off
        case starting
        /// Server bound, no client attached.
        case listening(Session)
        /// At least one `claude` process attached via `/ide`.
        case connected(Session, clients: Int)
        case failed(String)

        var session: Session? {
            switch self {
            case .listening(let session): return session
            case .connected(let session, _): return session
            default: return nil
            }
        }

        var port: UInt16? { session?.port }

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
                    onClientCountChange: { [weak self] count in
                        Task { @MainActor in self?.clientCountChanged(count) }
                    },
                    onFailure: { [weak self] message in
                        Task { @MainActor in self?.serverFailed(message, generation: gen) }
                    })
                guard generation == gen else {
                    await server.stop()
                    return
                }

                // Publish the session BEFORE the lock file: a client that
                // connects the instant the file appears must find it in place,
                // or `clientCountChanged` drops the transition.
                state = .listening(Session(port: port, token: token, folders: folders))

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
                tearDown(reason: "start failed",
                         into: .failed(String(describing: error)),
                         stopServer: false)
            }
        }
    }

    func stop() {
        guard state != .off else { return }
        tearDown(reason: "integration stopped", into: .off)
    }

    /// App termination: the lock file must be gone before we exit, so this one
    /// call does the removal synchronously (and skips the pointless server stop).
    func stopBeforeTerminate() {
        tearDown(reason: "app terminating", into: .off, synchronous: true)
    }

    /// The server tore itself down (listener failed after start). Lands in
    /// `.failed` so the chip says why `/ide` stopped finding us.
    private func serverFailed(_ message: String, generation failedGeneration: Int) {
        guard generation == failedGeneration else { return }
        tearDown(reason: "server failed", into: .failed(message), stopServer: false)
    }

    /// The single teardown ritual: bump the epoch (stale start tasks abort),
    /// release blocked `openDiff`s, retire the lock file, land in `finalState`.
    /// Session identity lives inside `state`, so no path can forget part of it.
    private func tearDown(reason: String, into finalState: State,
                          stopServer: Bool = true, synchronous: Bool = false) {
        generation += 1
        DiffApprovalController.shared.rejectAll(reason: reason)
        let session = state.session
        let directory = lockDirectory
        state = finalState
        if synchronous {
            if let session { IDELockFile.remove(port: session.port, in: directory) }
            return
        }
        Task {
            if stopServer { await server.stop() }
            if let session {
                await Task.detached { IDELockFile.remove(port: session.port, in: directory) }.value
            }
        }
    }

    private func clientCountChanged(_ count: Int) {
        guard let session = state.session else { return }
        if count > 0 {
            state = .connected(session, clients: count)
        } else {
            // Last client left mid-diff: release the blocked `openDiff` calls.
            DiffApprovalController.shared.rejectAll(reason: "client disconnected")
            state = .listening(session)
        }
    }

    // MARK: Workspace folders

    /// The CLI matches its cwd against `workspaceFolders` at `/ide` time.
    /// Rewrite the file in place (same port, same token) when the set changes —
    /// a live connection survives it (verified by hand, see HISTORY v36).
    func refreshWorkspaceFolders() {
        guard let session = state.session else { return }
        let folders = claudeIDEWorkspaceFolders().map(\.path)
        guard folders != session.folders else { return }
        var updated = session
        updated.folders = folders
        switch state {
        case .listening: state = .listening(updated)
        case .connected(_, let clients): state = .connected(updated, clients: clients)
        default: return
        }
        let directory = lockDirectory
        let contents = IDELockFileContents(workspaceFolders: folders, authToken: session.token)
        Task.detached {
            do {
                _ = try IDELockFile.write(contents, port: session.port, in: directory)
            } catch {
                claudeIDELog.error("Lock rewrite failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Notifications IDE → Claude

    func notifySelectionChanged(_ selection: IDESelection) {
        guard isConnected else { return }
        // Same wire shape as the getCurrentSelection reply (IDESelection owns it).
        let params = JSONValue.object(selection.payloadFields)
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
