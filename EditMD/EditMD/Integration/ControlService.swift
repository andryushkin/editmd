import Foundation
import os

/// Lifecycle owner of the control socket (v38). Always on while the app runs
/// (not gated by a setting — scripts and `editmdctl` should just work).
/// Skipped under XCTest so the test host doesn't bind the user's real socket.
@MainActor
final class ControlService: ObservableObject {

    static let shared = ControlService()

    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?

    /// Resolved path (env override or default Application Support path).
    private(set) var socketPath: URL = ControlSocket.defaultPath()

    private let server = ControlServer()

    private init() {}

    func activate() {
        if let env = ProcessInfo.processInfo.environment[ControlSocket.envOverride],
           !env.isEmpty {
            socketPath = URL(fileURLWithPath: env)
        } else {
            socketPath = ControlSocket.defaultPath()
        }
        start()
    }

    func start() {
        let path = socketPath
        // Bind off the main actor — `bind`/`listen` are fast but don't belong
        // on the UI thread (v35.3 spirit).
        DispatchQueue.global(qos: .userInitiated).async { [server] in
            do {
                try server.start(socketPath: path)
                DispatchQueue.main.async {
                    self.isListening = true
                    self.lastError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.isListening = false
                    self.lastError = String(describing: error)
                    controlLog.error("control start failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func stopBeforeTerminate() {
        server.stop()
        isListening = false
    }
}
