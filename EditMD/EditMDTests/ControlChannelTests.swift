import XCTest
@testable import EditMD

/// Control protocol codec, skill installer, socket round-trip.
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
                     "marks.list", "marks.add", "diff.show", "workspace.add",
                     "agent-status",
                     // Vault-graph commands.
                     "links.outgoing", "links.backlinks", "links.resolve",
                     "outline", "lint.workspace", "lint.file", "index.status",
                     "tags.list", "tags.files", "frontmatter.get"] {
            XCTAssertTrue(names.contains(need), "missing \(need)")
        }
    }

    // MARK: - Vault-graph commands

    private func makeVault() throws -> (root: URL, a: URL, b: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        try "[[b]] and [[missing]]\n".write(to: a, atomically: true, encoding: .utf8)
        try "# Target\ntext\n".write(to: b, atomically: true, encoding: .utf8)
        return (root.standardizedFileURL, a.standardizedFileURL, b.standardizedFileURL)
    }

    /// Seeds `LinkIndex.shared` the way a completed scan would.
    @MainActor
    private func seedSharedIndex(root: URL, a: URL, b: URL) {
        let resolved = OutgoingLink(
            kind: .wiki, rawTarget: "b", label: "b", line: 1,
            utf16Offset: 0, context: "[[b]] and [[missing]]",
            resolved: b, candidates: [b])
        let dead = OutgoingLink(
            kind: .wiki, rawTarget: "missing", label: "missing", line: 1,
            utf16Offset: 10, context: "[[b]] and [[missing]]")
        LinkIndex.shared.seedForTesting(
            outgoing: [a: [resolved, dead], b: []],
            headings: [b: ["Target"]],
            roots: [root],
            key: "ctl-test")
    }

    func testScopePredicate() {
        let vault = URL(fileURLWithPath: "/vault")
        // Non-empty roots reject an outside path — this is the cold-app case
        // too (roots come from linkIndexRoots when the index is empty).
        XCTAssertTrue(ControlRouter.isOutsideScope("/other/x.md", roots: [vault]))
        XCTAssertFalse(ControlRouter.isOutsideScope("/vault/a.md", roots: [vault]))
        XCTAssertFalse(ControlRouter.isOutsideScope("/vault", roots: [vault]))
        // Empty roots = true loose mode → never outside.
        XCTAssertFalse(ControlRouter.isOutsideScope("/anywhere.md", roots: []))
    }

    @MainActor
    func testControlMissingInScopeFileReportsNotFound() throws {
        let (root, a, b) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        seedSharedIndex(root: root, a: a, b: b)

        // A path INSIDE the active workspace that is not on disk and not in the
        // graph must report file-not-found, not "succeed empty" (contract
        // parity with the offline engine).
        let ghost = root.appendingPathComponent("ghost.md").path
        for cmd in ["links.outgoing", "links.backlinks", "outline",
                    "lint.file", "frontmatter.get"] {
            let resp = ControlRouter.process(ControlRequest(
                id: "1", cmd: cmd, args: ["path": .string(ghost)]))
            XCTAssertFalse(resp.ok, "\(cmd) must 404 a missing in-scope file")
            XCTAssertEqual(resp.error?.contains("file not found"), true,
                           "\(cmd): \(resp.error ?? "")")
        }
    }

    @MainActor
    func testControlVaultGraphRejectsOutsideActiveWorkspace() throws {
        let (root, a, b) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        seedSharedIndex(root: root, a: a, b: b)

        // A path outside the indexed workspace must fail on every path-based
        // command — not just paths in another adopted workspace.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-outside-\(UUID().uuidString).md").path
        for cmd in ["links.outgoing", "links.backlinks", "outline",
                    "lint.file", "frontmatter.get"] {
            let resp = ControlRouter.process(ControlRequest(
                id: "1", cmd: cmd, args: ["path": .string(outside)]))
            XCTAssertFalse(resp.ok, "\(cmd) must reject outside path")
            XCTAssertEqual(resp.error?.contains("outside-active-workspace"), true,
                           "\(cmd): \(resp.error ?? "")")
        }
        // An in-workspace path still works.
        let ok = ControlRouter.process(ControlRequest(
            id: "2", cmd: "outline", args: ["path": .string(b.path)]))
        XCTAssertTrue(ok.ok, ok.error ?? "")
    }

    @MainActor
    func testControlLinksOutgoingAndBacklinks() throws {
        let (root, a, b) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        seedSharedIndex(root: root, a: a, b: b)

        let out = ControlRouter.process(ControlRequest(
            id: "1", cmd: "links.outgoing", args: ["path": .string(a.path)]))
        XCTAssertTrue(out.ok, out.error ?? "")
        guard case let .object(data)? = out.data,
              case let .array(links)? = data["links"] else {
            return XCTFail("bad payload")
        }
        XCTAssertEqual(data["count"], .int(2))
        guard case let .object(first) = links[0],
              case let .object(second) = links[1] else {
            return XCTFail("bad link payload")
        }
        XCTAssertEqual(first["status"], .string("resolved"))
        XCTAssertEqual(first["path"], .string(b.path))
        XCTAssertEqual(second["status"], .string("dead"))
        XCTAssertEqual(second["target"], .string("missing"))

        let back = ControlRouter.process(ControlRequest(
            id: "2", cmd: "links.backlinks", args: ["path": .string(b.path)]))
        XCTAssertTrue(back.ok, back.error ?? "")
        guard case let .object(bData)? = back.data,
              case let .array(edges)? = bData["backlinks"],
              case let .object(edge) = edges.first else {
            return XCTFail("bad backlinks payload")
        }
        XCTAssertEqual(bData["count"], .int(1))
        XCTAssertEqual(edge["source"], .string(a.path))
        XCTAssertEqual(edge["target"], .string("b"))
    }

    @MainActor
    func testControlLintFileAndWorkspace() throws {
        let (root, a, b) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        seedSharedIndex(root: root, a: a, b: b)

        let file = ControlRouter.process(ControlRequest(
            id: "1", cmd: "lint.file", args: ["path": .string(a.path)]))
        XCTAssertTrue(file.ok, file.error ?? "")
        guard case let .object(data)? = file.data,
              case let .array(findings)? = data["findings"],
              case let .object(finding) = findings.first else {
            return XCTFail("bad lint payload")
        }
        XCTAssertEqual(finding["rule"], .string("deadWikiLink"))
        XCTAssertEqual(finding["target"], .string("missing"))

        let ws = ControlRouter.process(ControlRequest(
            id: "2", cmd: "lint.workspace", args: ["limit": .int(10)]))
        XCTAssertTrue(ws.ok, ws.error ?? "")
        guard case let .object(wsData)? = ws.data,
              case let .array(wsFindings)? = wsData["findings"] else {
            return XCTFail("bad workspace lint payload")
        }
        // At least the dead wiki link; orphan rules may add more.
        XCTAssertTrue(wsFindings.contains { item in
            guard case let .object(o) = item else { return false }
            return o["rule"] == .string("deadWikiLink")
        })
    }

    @MainActor
    func testControlLinksResolveOutlineFrontmatterIndexStatus() throws {
        let (root, a, b) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        ---
        title: Target Note
        tags: [x, y]
        ---

        # Target
        ## Sub
        """.write(to: b, atomically: true, encoding: .utf8)
        seedSharedIndex(root: root, a: a, b: b)

        let resolve = ControlRouter.process(ControlRequest(
            id: "1", cmd: "links.resolve", args: ["target": .string("b")]))
        XCTAssertTrue(resolve.ok, resolve.error ?? "")
        guard case let .object(rData)? = resolve.data else {
            return XCTFail("bad resolve payload")
        }
        XCTAssertEqual(rData["status"], .string("resolved"))
        XCTAssertEqual(rData["path"], .string(b.path))

        let outline = ControlRouter.process(ControlRequest(
            id: "2", cmd: "outline", args: ["path": .string(b.path)]))
        XCTAssertTrue(outline.ok, outline.error ?? "")
        guard case let .object(oData)? = outline.data,
              case let .array(items)? = oData["outline"],
              case let .object(item) = items.first else {
            return XCTFail("bad outline payload")
        }
        XCTAssertEqual(oData["count"], .int(2))
        XCTAssertEqual(item["title"], .string("Target"))
        XCTAssertEqual(item["level"], .int(1))

        let fm = ControlRouter.process(ControlRequest(
            id: "3", cmd: "frontmatter.get", args: ["path": .string(b.path)]))
        XCTAssertTrue(fm.ok, fm.error ?? "")
        guard case let .object(fmData)? = fm.data,
              case let .array(props)? = fmData["properties"] else {
            return XCTFail("bad frontmatter payload")
        }
        XCTAssertEqual(fmData["present"], .bool(true))
        XCTAssertTrue(props.contains { item in
            guard case let .object(o) = item else { return false }
            return o["key"] == .string("title") && o["value"] == .string("Target Note")
        })

        let status = ControlRouter.process(ControlRequest(id: "4", cmd: "index.status"))
        XCTAssertTrue(status.ok, status.error ?? "")
        guard case let .object(sData)? = status.data else {
            return XCTFail("bad status payload")
        }
        XCTAssertEqual(sData["ready"], .bool(true))
        XCTAssertEqual(sData["files"], .int(2))
        XCTAssertEqual(sData["persisted"], JSONValue.null)
    }

    @MainActor
    func testControlFrontmatterAbsent() throws {
        let (root, a, b) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        seedSharedIndex(root: root, a: a, b: b)
        let fm = ControlRouter.process(ControlRequest(
            id: "1", cmd: "frontmatter.get", args: ["path": .string(a.path)]))
        XCTAssertTrue(fm.ok, fm.error ?? "")
        guard case let .object(data)? = fm.data else {
            return XCTFail("bad payload")
        }
        XCTAssertEqual(data["present"], .bool(false))
    }

    func testParseAgentStatusArgs() {
        let ok = parseAgentStatusArgs([
            "status": .string("active"),
            "label": .string("thinking"),
            "harness": .string("codex"),
        ])
        XCTAssertEqual(ok?.status, "active")
        XCTAssertEqual(ok?.label, "thinking")
        XCTAssertEqual(ok?.harness, "codex")
        XCTAssertNil(parseAgentStatusArgs(nil))
        XCTAssertTrue(agentStatusKnownStates.contains("blocked"))
    }

    func testWorkspaceAddCommandName() {
        XCTAssertEqual(ControlCommandName.workspaceAdd.rawValue, "workspace.add")
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

    // MARK: marks.add durability

    /// The reply to marks.add must mean "durable on disk": the very next CLI
    /// call (queue build, `/smotr -pr`) reads the sidecar file directly.
    func testControlMarksAddDurableBeforeReply() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-ctl-marks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.md")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)

        let req = ControlRequest(id: "m1", cmd: "marks.add", args: [
            "path": .string(file.path),
            "type": .string("comment"),
            "note": .string("сноска"),
            "quote": .string("hello"),
        ])
        let exp = expectation(description: "marks.add")
        var resp: ControlResponse?
        DispatchQueue.global(qos: .userInitiated).async {
            resp = ControlRouter.process(req)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        let r = try XCTUnwrap(resp)
        XCTAssertTrue(r.ok, r.error ?? "")
        // Immediately after the reply the mark is on disk, rev matches.
        let disk = ReviewSidecar.loadOrEmpty(for: file)
        XCTAssertEqual(disk.marks.count, 1)
        XCTAssertEqual(disk.marks.first?.note, "сноска")
        XCTAssertEqual(r.data?["path"], .string(file.standardizedFileURL.path))
        XCTAssertEqual(r.data?["rev"], .int(disk.rev))
    }

    /// A control request can arrive after the source disappeared from disk but
    /// before the in-flight move publishes its final path. The synchronous
    /// AppState precheck must admit it, and ReviewModel's barrier must relocate
    /// the queued disk read before the socket follow-up runs.
    @MainActor
    func testControlMarksListFollowsMissingPathThroughActiveGate() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "editmd-ctl-gated-marks-\(UUID().uuidString)",
                isDirectory: true)
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        let destinationFolder = root.appendingPathComponent(
            "destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destinationFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldFile = sourceFolder.appendingPathComponent("note.md")
        let newFile = destinationFolder.appendingPathComponent("note.md")
        try "hello".write(to: oldFile, atomically: true, encoding: .utf8)

        let routeToken = AppState.shared.beginPathMutation(at: oldFile)
        let reviewToken = await ReviewModel.shared.beginPathMutation()
        var completed = false
        defer {
            if !completed {
                ReviewModel.shared.cancelPathMutation(reviewToken)
                AppState.shared.finishPathMutation(routeToken)
            }
        }

        try FileManager.default.moveItem(at: oldFile, to: newFile)
        let request = ControlRequest(
            id: "gated-list",
            cmd: "marks.list",
            args: ["path": .string(oldFile.path)])
        guard case .followUp(let followUp) = ControlRouter.handle(request) else {
            return XCTFail("marks.list must enqueue a deferred disk read")
        }

        ReviewModel.shared.completePathMutation(
            reviewToken,
            relocatingFiles: [.init(from: oldFile, to: newFile)])
        AppState.shared.relocateFile(from: oldFile, to: newFile)
        AppState.shared.finishPathMutation(routeToken)
        completed = true

        let response = await Task.detached { followUp() }.value
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.data?["path"],
                       .string(newFile.standardizedFileURL.path))
        XCTAssertEqual(response.data?["count"], .int(0))
    }

    @MainActor
    func testControlMarksAddFollowsMissingPathThroughActiveGate() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "editmd-ctl-gated-add-\(UUID().uuidString)",
                isDirectory: true)
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        let destinationFolder = root.appendingPathComponent(
            "destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destinationFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldFile = sourceFolder.appendingPathComponent("note.md")
        let newFile = destinationFolder.appendingPathComponent("note.md")
        try "hello".write(to: oldFile, atomically: true, encoding: .utf8)

        let routeToken = AppState.shared.beginPathMutation(at: oldFile)
        let reviewToken = await ReviewModel.shared.beginPathMutation()
        var completed = false
        defer {
            if !completed {
                ReviewModel.shared.cancelPathMutation(reviewToken)
                AppState.shared.finishPathMutation(routeToken)
            }
        }

        try FileManager.default.moveItem(at: oldFile, to: newFile)
        let request = ControlRequest(
            id: "gated-add",
            cmd: "marks.add",
            args: [
                "path": .string(oldFile.path),
                "type": .string("comment"),
                "quote": .string("hello"),
                "note": .string("follow the move"),
            ])
        guard case .followUp(let followUp) = ControlRouter.handle(request) else {
            return XCTFail("marks.add must enqueue a deferred disk write")
        }

        ReviewModel.shared.completePathMutation(
            reviewToken,
            relocatingFiles: [.init(from: oldFile, to: newFile)])
        AppState.shared.relocateFile(from: oldFile, to: newFile)
        AppState.shared.finishPathMutation(routeToken)
        completed = true

        let response = await Task.detached { followUp() }.value
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.data?["path"],
                       .string(newFile.standardizedFileURL.path))
        let disk = ReviewSidecar.loadOrEmpty(for: newFile)
        XCTAssertEqual(disk.marks.map(\.note), ["follow the move"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ReviewSidecar.url(for: oldFile).path))
    }

    // MARK: Paths, off-main diff, pending jump

    /// The app's cwd is "/" under Finder — resolving relative paths there
    /// targets the wrong file, so the router must reject them outright
    /// (editmdctl absolutizes against the caller's cwd before sending).
    func testControlRejectsRelativePath() throws {
        let req = ControlRequest(id: "r1", cmd: "marks.list",
                                 args: ["path": .string("relative/notes.md")])
        let exp = expectation(description: "relative path")
        var resp: ControlResponse?
        DispatchQueue.global(qos: .userInitiated).async {
            resp = ControlRouter.process(req)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        let r = try XCTUnwrap(resp)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.error?.contains("absolute") == true, r.error ?? "")
    }

    func testControlDiffShowCleanFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-ctl-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clean.md")
        try "# clean\n".write(to: file, atomically: true, encoding: .utf8)

        let req = ControlRequest(id: "d1", cmd: "diff.show",
                                 args: ["path": .string(file.path)])
        let exp = expectation(description: "diff.show")
        var resp: ControlResponse?
        DispatchQueue.global(qos: .userInitiated).async {
            resp = ControlRouter.process(req)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        let r = try XCTUnwrap(resp)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.data?["dirty"]?.boolValue, false)
    }

    /// The pending jump waits for its exact file and is consumed exactly once
    /// — the old fixed-delay notification dropped it when the file opened
    /// slower than the timer.
    @MainActor
    func testControlJumpPendingConsumedOnce() {
        let url = URL(fileURLWithPath: "/tmp/editmd-jump-\(UUID().uuidString).md")
        AppState.shared.requestControlJump(url: url, offset: 42)
        XCTAssertNil(AppState.shared.consumeControlJump(
            for: URL(fileURLWithPath: "/tmp/other.md")),
            "jump must wait for its own file")
        XCTAssertEqual(AppState.shared.consumeControlJump(for: url), 42)
        XCTAssertNil(AppState.shared.consumeControlJump(for: url),
                     "consume must clear the pending jump")
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
