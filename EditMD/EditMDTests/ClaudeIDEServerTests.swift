import Network
import XCTest
@testable import EditMD

/// Step 1.1 gate, transport half: a real WebSocket client against the real
/// listener. The auth header is the only thing keeping any local process out of
/// the user's documents, so "wrong token cannot upgrade" is asserted for real,
/// not mocked.
final class ClaudeIDEServerTests: XCTestCase {

    private var server: ClaudeIDEServer!
    private let token = "0123456789abcdef0123456789abcdef"

    override func setUp() async throws {
        server = ClaudeIDEServer()
    }

    override func tearDown() async throws {
        await server.stop()
        server = nil
    }

    /// Echoes the method back so the test can prove the frame made it through.
    private func startEchoServer() async throws -> UInt16 {
        try await server.start(authToken: token) { request in
            guard let id = request.id else { return nil }
            return .result(id: id, .object(["method": .string(request.method)]))
        }
    }

    // MARK: - Auth

    func testUpgradeSucceedsWithCorrectToken() async throws {
        let port = try await startEchoServer()
        let client = WebSocketTestClient(port: port, token: token)
        defer { client.close() }
        try await client.waitUntilReady(timeout: 5)
    }

    func testUpgradeFailsWithWrongToken() async throws {
        let port = try await startEchoServer()
        let client = WebSocketTestClient(port: port, token: "wrong-token")
        defer { client.close() }
        await assertUpgradeRejected(client)
    }

    func testUpgradeFailsWithNoAuthHeader() async throws {
        let port = try await startEchoServer()
        let client = WebSocketTestClient(port: port, token: nil)
        defer { client.close() }
        await assertUpgradeRejected(client)
    }

    /// A rejected upgrade never reaches `.ready`: Network aborts the TCP
    /// connection, which surfaces as `.waiting`/`.failed` on the client.
    private func assertUpgradeRejected(_ client: WebSocketTestClient) async {
        do {
            try await client.waitUntilRejected(timeout: 5)
        } catch {
            XCTFail("Expected a rejected upgrade, got \(error)")
        }
    }

    // MARK: - Lifecycle

    func testPortIsEphemeralAndReportedAfterStart() async throws {
        let port = try await startEchoServer()
        XCTAssertGreaterThan(port, 1024)
        let reported = await server.port
        XCTAssertEqual(reported, port)
        let running = await server.isRunning
        XCTAssertTrue(running)
    }

    func testStartTwiceThrows() async throws {
        _ = try await startEchoServer()
        do {
            _ = try await startEchoServer()
            XCTFail("Second start should throw")
        } catch let error as ClaudeIDEServerError {
            XCTAssertEqual(error, .alreadyRunning)
        }
    }

    func testStopClearsPortAndClients() async throws {
        _ = try await startEchoServer()
        await server.stop()
        let port = await server.port
        XCTAssertNil(port)
        let running = await server.isRunning
        XCTAssertFalse(running)
    }

    // MARK: - Round-trip

    func testRequestGetsAResponseAndNotificationDoesNot() async throws {
        let port = try await startEchoServer()
        let client = WebSocketTestClient(port: port, token: token)
        defer { client.close() }
        try await client.waitUntilReady(timeout: 5)

        // A notification (no id) must not be answered — a reply to one is a
        // protocol violation that confuses the CLI.
        client.send(#"{"jsonrpc":"2.0","method":"initialized"}"#)
        client.send(#"{"jsonrpc":"2.0","id":11,"method":"tools/list"}"#)

        let reply = try await client.nextMessage(timeout: 5)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 11)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["method"] as? String, "tools/list")
    }

    func testClientCountIsReported() async throws {
        let counts = CountRecorder()
        let port = try await server.start(
            authToken: token,
            handler: { _ in nil },
            onClientCountChange: { count in counts.record(count) })

        let client = WebSocketTestClient(port: port, token: token)
        try await client.waitUntilReady(timeout: 5)
        try await waitUntil(timeout: 3) { counts.last == 1 }

        client.close()
        try await waitUntil(timeout: 3) { counts.last == 0 }
    }

    /// Polls `condition` instead of sleeping a fixed interval — network state
    /// transitions are asynchronous and a fixed sleep is a flake generator.
    private func waitUntil(timeout: TimeInterval,
                           _ condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }
}

// MARK: - Test helpers

/// Thread-safe recorder for the server's `@Sendable` client-count callback.
private final class CountRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func record(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        counts.append(count)
    }

    var last: Int? {
        lock.lock(); defer { lock.unlock() }
        return counts.last
    }
}

/// Minimal WebSocket client speaking the same handshake the CLI uses.
private final class WebSocketTestClient: @unchecked Sendable {

    enum ClientError: Error { case timeout, failed, becameReady }

    private let connection: NWConnection
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var state: NWConnection.State = .setup

    init(port: UInt16, token: String?) {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        if let token {
            websocket.setAdditionalHeaders([(name: claudeIDEAuthHeader, value: token)])
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        // Must be a `ws://` URL endpoint: a host/port endpoint never emits the
        // HTTP upgrade request, so the server's handshake handler never fires
        // and the connection is aborted. (The CLI dials by URL too.)
        connection = NWConnection(
            to: .url(URL(string: "ws://127.0.0.1:\(port)/")!), using: parameters)
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            self.lock.lock()
            self.state = newState
            self.lock.unlock()
        }
        connection.start(queue: .global())
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.inbox.append(data)
                self.lock.unlock()
            }
            self.receive()
        }
    }

    func waitUntilReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // `lock()`/`unlock()` are unavailable in async contexts; the scoped
            // form cannot straddle a suspension point.
            let current = lock.withLock { state }
            switch current {
            case .ready: return
            case .failed, .cancelled: throw ClientError.failed
            default: break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw ClientError.timeout
    }

    /// Returns once the connection is provably not going to upgrade.
    func waitUntilRejected(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch lock.withLock({ state }) {
            case .ready: throw ClientError.becameReady
            case .failed, .cancelled, .waiting: return
            default: break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw ClientError.timeout
    }

    func send(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "t", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context,
                        isComplete: true, completion: .contentProcessed { _ in })
    }

    func nextMessage(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = lock.withLock { inbox.isEmpty ? nil : inbox.removeFirst() }
            if let message { return message }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw ClientError.timeout
    }

    func close() {
        connection.cancel()
    }
}
