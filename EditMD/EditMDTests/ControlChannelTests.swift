import XCTest
@testable import EditMD

/// Phase 3 (v38) — control protocol codec, skill installer, socket round-trip.
final class ControlChannelTests: XCTestCase {

    // MARK: Codec

    func testRequestResponseRoundTrip() throws {
        let req = ControlRequest(id: "7", cmd: "open",
                                 args: ["path": .string("/tmp/a.md"), "line": .int(3)])
        let line = try ControlCodec.encodeRequest(req)
        XCTAssertTrue(line.hasSuffix("\n"))
        let decoded = try ControlCodec.decodeRequest(line)
        XCTAssertEqual(decoded.id, "7")
        XCTAssertEqual(decoded.cmd, "open")
        XCTAssertEqual(decoded.argString("path"), "/tmp/a.md")
        XCTAssertEqual(decoded.argInt("line"), 3)

        let resp = ControlResponse.success(id: "7", data: .object(["ok": .bool(true)]))
        let rLine = try ControlCodec.encodeResponse(resp)
        let rDec = try ControlCodec.decodeResponse(rLine)
        XCTAssertTrue(rDec.ok)
        XCTAssertEqual(rDec.id, "7")
    }

    func testFailureResponse() throws {
        let resp = ControlResponse.failure(id: "1", error: "nope")
        let line = try ControlCodec.encodeResponse(resp)
        let d = try ControlCodec.decodeResponse(line)
        XCTAssertFalse(d.ok)
        XCTAssertEqual(d.error, "nope")
    }

    func testEmptyLineThrows() {
        XCTAssertThrowsError(try ControlCodec.decodeRequest("   \n"))
    }

    func testKnownCommandsCoverPlan() {
        let names = Set(ControlCommandName.allCases.map(\.rawValue))
        for need in ["ping", "status", "open", "reveal", "mode",
                     "marks.list", "marks.add", "diff.show"] {
            XCTAssertTrue(names.contains(need), "missing \(need)")
        }
    }

    func testSocketPathDefault() {
        let p = ControlSocket.defaultPath(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(p.path,
                       "/Users/x/Library/Application Support/EditMD/control.sock")
    }

    // MARK: Skill installer

    func testSkillInstallFreshAndIdempotent() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = "# skill v1\n"
        let r1 = try SkillInstaller.install(content: content, to: dir)
        guard case .installed(let url) = r1 else {
            return XCTFail("expected installed, got \(r1)")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), content)

        let r2 = try SkillInstaller.install(content: content, to: dir)
        guard case .unchanged = r2 else {
            return XCTFail("expected unchanged, got \(r2)")
        }

        let r3 = try SkillInstaller.install(content: "# skill v2\n", to: dir)
        guard case .updated = r3 else {
            return XCTFail("expected updated, got \(r3)")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# skill v2\n")
    }

    func testSkillDiffNonEmptyOnChange() {
        let diff = SkillInstaller.unifiedDiff(old: "a\n", new: "b\n")
        XCTAssertTrue(diff.contains("---"))
        XCTAssertTrue(diff.contains("+++"))
    }

    /// Test host = EditMD.app, so this checks the REAL bundle layout: xcodegen
    /// copies SKILL.md flat into Contents/Resources/ — if the lookup misses it,
    /// Help ▸ Install Agent Skill is dead in the shipped app.
    func testBundledSkillResolvesInAppBundle() {
        XCTAssertNotNil(SkillInstaller.bundledContent(bundle: .main),
                        "bundled SKILL.md not found — check bundledSkillURL against the app's Resources layout")
    }

    // MARK: Live socket (ping)

    /// Client I/O must NOT run on the main thread: the server hops to main
    /// via `DispatchQueue.main.sync`, so a main-thread client would deadlock.
    func testSocketPingRoundTrip() throws {
        let sock = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-ctl-\(UUID().uuidString).sock")
        let server = ControlServer()
        try server.start(socketPath: sock)
        defer { server.stop() }

        let exp = expectation(description: "ping")
        var resp: ControlResponse?
        var clientError: Error?
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                Thread.sleep(forTimeInterval: 0.05)
                let req = ControlRequest(id: "ping-1", cmd: "ping")
                let payload = try ControlCodec.encodeRequest(req)
                let respLine = try Self.clientRoundTrip(socketPath: sock.path,
                                                         requestLine: payload)
                resp = try ControlCodec.decodeResponse(respLine)
            } catch {
                clientError = error
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        XCTAssertNil(clientError, String(describing: clientError))
        let r = try XCTUnwrap(resp)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.id, "ping-1")
        XCTAssertEqual(r.data?["pong"]?.boolValue, true)
    }

    func testSocketUnknownCommand() throws {
        let sock = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-ctl-\(UUID().uuidString).sock")
        let server = ControlServer()
        try server.start(socketPath: sock)
        defer { server.stop() }

        let exp = expectation(description: "unknown")
        var resp: ControlResponse?
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                Thread.sleep(forTimeInterval: 0.05)
                let req = ControlRequest(id: "x", cmd: "nope")
                let payload = try ControlCodec.encodeRequest(req)
                let respLine = try Self.clientRoundTrip(socketPath: sock.path,
                                                         requestLine: payload)
                resp = try ControlCodec.decodeResponse(respLine)
            } catch { /* leave nil */ }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        let r = try XCTUnwrap(resp)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.error?.contains("unknown") == true)
    }

    /// An idle client holding an open connection must not starve other
    /// clients: accepts and per-client serve loops run independently.
    func testIdleClientDoesNotStarveOthers() throws {
        let sock = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-ctl-\(UUID().uuidString).sock")
        let server = ControlServer()
        try server.start(socketPath: sock)
        defer { server.stop() }

        let exp = expectation(description: "ping despite idle client")
        var resp: ControlResponse?
        var clientError: Error?
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                Thread.sleep(forTimeInterval: 0.05)
                // First client connects and stays silent.
                let idle = try Self.connectClient(socketPath: sock.path)
                defer { close(idle) }
                // Second client must still round-trip.
                let req = ControlRequest(id: "busy-1", cmd: "ping")
                let payload = try ControlCodec.encodeRequest(req)
                let respLine = try Self.clientRoundTrip(socketPath: sock.path,
                                                        requestLine: payload)
                resp = try ControlCodec.decodeResponse(respLine)
            } catch {
                clientError = error
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNil(clientError, String(describing: clientError))
        XCTAssertEqual(resp?.ok, true)
    }

    /// A client that sends a request and disconnects without reading must not
    /// take the server down (SIGPIPE) — the next client still gets served.
    func testEarlyDisconnectDoesNotKillServer() throws {
        let sock = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-ctl-\(UUID().uuidString).sock")
        let server = ControlServer()
        try server.start(socketPath: sock)
        defer { server.stop() }

        let exp = expectation(description: "server survives early disconnect")
        var resp: ControlResponse?
        var clientError: Error?
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                Thread.sleep(forTimeInterval: 0.05)
                // Fire a request and slam the connection shut before the reply.
                let rude = try Self.connectClient(socketPath: sock.path)
                let line = try ControlCodec.encodeRequest(
                    ControlRequest(id: "rude", cmd: "ping"))
                let bytes = Array(line.utf8)
                _ = bytes.withUnsafeBufferPointer { buf in
                    Darwin.write(rude, buf.baseAddress!, bytes.count)
                }
                close(rude)
                // Give the server time to try writing into the closed socket.
                Thread.sleep(forTimeInterval: 0.2)
                let req = ControlRequest(id: "after", cmd: "ping")
                let payload = try ControlCodec.encodeRequest(req)
                let respLine = try Self.clientRoundTrip(socketPath: sock.path,
                                                        requestLine: payload)
                resp = try ControlCodec.decodeResponse(respLine)
            } catch {
                clientError = error
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNil(clientError, String(describing: clientError))
        XCTAssertEqual(resp?.ok, true)
        XCTAssertEqual(resp?.id, "after")
    }

    func testFormatUnifiedDiff() {
        let d = formatUnifiedDiff(old: "a\nb\n", new: "a\nc\n",
                                  oldName: "old", newName: "new")
        XCTAssertTrue(d.contains("--- old"))
        XCTAssertTrue(d.contains("+++ new"))
        XCTAssertTrue(d.contains("-b") || d.contains("-b\n"))
        XCTAssertTrue(d.contains("+c") || d.contains("+c\n"))
    }

    // MARK: Client helper

    /// Connects to the unix socket and returns the fd (caller closes).
    private static func connectClient(socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "ctl", code: 1) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() { buf[i] = UInt8(bitPattern: b) }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            close(fd)
            throw NSError(domain: "ctl", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "connect \(errno)"])
        }
        return fd
    }

    private static func clientRoundTrip(socketPath: String, requestLine: String) throws -> String {
        let fd = try connectClient(socketPath: socketPath)
        defer { close(fd) }

        let bytes = Array(requestLine.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            Darwin.write(fd, buf.baseAddress!, bytes.count)
        }

        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let n = read(fd, &tmp, tmp.count)
            if n > 0 {
                buffer.append(contentsOf: tmp[0..<n])
                if let nl = buffer.firstIndex(of: 0x0A) {
                    return String(data: buffer.subdata(in: 0..<nl), encoding: .utf8) ?? ""
                }
            } else if n == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        throw NSError(domain: "ctl", code: 3, userInfo: [NSLocalizedDescriptionKey: "timeout"])
    }
}
