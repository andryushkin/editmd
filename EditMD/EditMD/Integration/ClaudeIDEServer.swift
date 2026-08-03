import Foundation
import Network
import os

// WebSocket transport for the Claude Code IDE channel.
//
// Claude Code (the CLI) discovers us through `~/.claude/ide/<port>.lock`
// (IDELockFile.swift), opens a WebSocket to 127.0.0.1:<port> carrying the
// header `x-claude-code-ide-authorization: <authToken>`, and then speaks MCP
// over JSON-RPC 2.0 (MCPProtocol.swift).
//
// Everything here runs OFF the main actor: the listener has its own dispatch
// queue and the server is an `actor`. The only bridge into the UI is the
// request handler, which the caller supplies (see `ClaudeIDEService`).

let claudeIDELog = Logger(subsystem: "andryushkin.EditMD", category: "claude-ide")

/// Header the CLI must present on the WebSocket upgrade.
let claudeIDEAuthHeader = "x-claude-code-ide-authorization"

/// MCP protocol revision the IDE channel is pinned to.
let claudeIDEProtocolVersion = "2025-03-26"

// MARK: - Server

actor ClaudeIDEServer {

    /// Answers one inbound request. `nil` = no reply (notification).
    /// The handler may suspend for a long time (`openDiff` waits for the user);
    /// the receive loop is re-armed before it is invoked.
    typealias RequestHandler = @Sendable (RPCRequest) async -> RPCMessage?

    /// Number of live client connections, pushed on every change.
    typealias ClientCountHandler = @Sendable (Int) -> Void

    /// The bound listener died after `start` returned. The server has already
    /// torn itself down when this fires; the owner must retire the lock file.
    typealias FailureHandler = @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "com.editmd.claude-ide.ws")

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var handler: RequestHandler?
    private var clientCountHandler: ClientCountHandler?
    private var failureHandler: FailureHandler?

    private(set) var port: UInt16?

    var clientCount: Int { connections.count }
    var isRunning: Bool { listener != nil }

    // MARK: Lifecycle

    /// Binds an ephemeral loopback port and starts accepting. Returns the port.
    /// Any upgrade without a matching auth header is rejected at the handshake.
    @discardableResult
    func start(authToken: String,
               handler: @escaping RequestHandler,
               onClientCountChange: ClientCountHandler? = nil,
               onFailure: FailureHandler? = nil) async throws -> UInt16 {
        guard listener == nil else {
            throw ClaudeIDEServerError.alreadyRunning
        }
        self.handler = handler
        self.clientCountHandler = onClientCountChange
        self.failureHandler = onFailure

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.setClientRequestHandler(queue) { _, headers in
            let presented = headers.first {
                $0.name.caseInsensitiveCompare(claudeIDEAuthHeader) == .orderedSame
            }?.value
            // Constant-time-ish compare is overkill on loopback, but a plain
            // mismatch must never upgrade: the token is the only thing standing
            // between any local process and the user's documents.
            guard let presented, presented == authToken else {
                claudeIDELog.error("WebSocket upgrade rejected: missing/invalid auth header")
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        // Bind the loopback address explicitly — never 0.0.0.0.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                func finish(_ result: Result<UInt16, Error>) {
                    let alreadyResumed = resumed.withLock { done -> Bool in
                        defer { done = true }
                        return done
                    }
                    guard !alreadyResumed else { return }
                    continuation.resume(with: result)
                }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        finish(.failure(ClaudeIDEServerError.noPort))
                        return
                    }
                    finish(.success(port))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(ClaudeIDEServerError.cancelled))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        // Ready: keep observing — a later failure must tear the server down,
        // or the lock file keeps advertising a dead port.
        let listenerID = ObjectIdentifier(listener)
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                claudeIDELog.error("Listener failed: \(String(describing: error), privacy: .public)")
                Task { await self?.listenerFailed(listenerID,
                                                  message: String(describing: error)) }
            }
        }

        port = boundPort
        claudeIDELog.info("Listening on 127.0.0.1:\(boundPort, privacy: .public)")
        return boundPort
    }

    func stop() {
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        port = nil
        handler = nil
        failureHandler = nil
        let notifyCount = clientCountHandler
        clientCountHandler = nil
        notifyCount?(0)
        claudeIDELog.info("Server stopped")
    }

    /// A bound listener died behind us. Guarded by identity so a stale callback
    /// from a previous listener can't kill a restarted server.
    private func listenerFailed(_ id: ObjectIdentifier, message: String) {
        guard let listener, ObjectIdentifier(listener) == id else { return }
        let notify = failureHandler
        stop()
        notify?(message)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.drop(key) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, key: key)
        claudeIDELog.info("Client connected (\(self.connections.count, privacy: .public) total)")
        clientCountHandler?(connections.count)
    }

    private func drop(_ key: ObjectIdentifier) {
        guard let connection = connections.removeValue(forKey: key) else { return }
        connection.cancel()
        claudeIDELog.info("Client disconnected (\(self.connections.count, privacy: .public) left)")
        clientCountHandler?(connections.count)
    }

    private func receive(on connection: NWConnection, key: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            Task { await self.handleFrame(data: data, context: context, error: error,
                                          connection: connection, key: key) }
        }
    }

    private func handleFrame(data: Data?,
                             context: NWConnection.ContentContext?,
                             error: NWError?,
                             connection: NWConnection,
                             key: ObjectIdentifier) {
        if let error {
            claudeIDELog.error("Receive failed: \(String(describing: error), privacy: .public)")
            drop(key)
            return
        }
        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata
        if metadata?.opcode == .close {
            drop(key)
            return
        }
        // Re-arm BEFORE dispatching: `openDiff` blocks until the user answers,
        // and the client keeps sending (`close_tab`, further tools) meanwhile.
        guard connections[key] != nil else { return }
        receive(on: connection, key: key)

        guard metadata?.opcode == .text, let data, !data.isEmpty else { return }

        let request: RPCRequest
        do {
            request = try MCPCodec.decode(data)
        } catch let rpcError as RPCError {
            send(.failure(id: nil, rpcError), on: connection)
            return
        } catch {
            send(.failure(id: nil, RPCError(code: RPCError.parseError, message: "Invalid JSON")),
                 on: connection)
            return
        }

        guard let handler else { return }
        // Inherits this actor's isolation, so `send` needs no hop — but the
        // handler may suspend for minutes (`openDiff`), hence the detour.
        Task {
            if let response = await handler(request) {
                self.send(response, on: connection)
            }
        }
    }

    // MARK: Sending

    private func send(_ message: RPCMessage, on connection: NWConnection) {
        guard let data = try? MCPCodec.encode(message) else {
            claudeIDELog.error("Failed to encode outbound message")
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "rpc", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { error in
            if let error {
                claudeIDELog.error("Send failed: \(String(describing: error), privacy: .public)")
            }
        })
    }

    /// Pushes an IDE→client notification (`selection_changed`, `at_mentioned`)
    /// to every connected client. No-op with no clients.
    func broadcast(method: String, params: JSONValue?) {
        guard !connections.isEmpty else { return }
        let message = RPCMessage.notification(method: method, params: params)
        for connection in connections.values {
            send(message, on: connection)
        }
    }
}

enum ClaudeIDEServerError: Error, Equatable {
    case alreadyRunning
    case noPort
    case cancelled
}

// MARK: - Method routing (MCP handshake + tools)

/// Turns an inbound `RPCRequest` into a reply. Handshake methods are answered
/// here; `tools/call` is delegated to `ClaudeIDETools`.
struct ClaudeIDERouter: Sendable {

    let tools: ClaudeIDETools

    func handle(_ request: RPCRequest) async -> RPCMessage? {
        // Notifications: acknowledge nothing, never reply (a reply to a
        // notification is a protocol violation and confuses the CLI).
        guard let id = request.id else {
            claudeIDELog.debug("notification \(request.method, privacy: .public)")
            return nil
        }

        switch request.method {
        case "initialize":
            return .result(id: id, .object([
                "protocolVersion": .string(claudeIDEProtocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("EditMD"),
                    "version": .string(appVersionString),
                ]),
            ]))

        case "tools/list":
            return .result(id: id, .object(["tools": .array(ClaudeIDETools.descriptors)]))

        case "tools/call":
            guard let name = request.params?["name"]?.stringValue else {
                return .failure(id: id, .invalidParams("tools/call requires a tool name"))
            }
            let arguments = request.params?["arguments"] ?? .object([:])
            let result = await tools.call(name: name, arguments: arguments)
            switch result {
            case .success(let value):
                return .result(id: id, value)
            case .failure(let error):
                return .failure(id: id, error)
            }

        case "ping":
            return .result(id: id, .object([:]))

        case "shutdown":
            return .result(id: id, .null)

        default:
            claudeIDELog.notice("Unknown method \(request.method, privacy: .public)")
            return .failure(id: id, .methodNotFound(request.method))
        }
    }
}

/// `CFBundleShortVersionString`, or `0` when running outside a bundle (tests).
var appVersionString: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
}
