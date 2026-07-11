import AppKit
import Foundation
import os

let controlLog = Logger(subsystem: "com.editmd.app", category: "control")

/// Executes control-channel commands on the main actor (v38).
/// Keeps disk IO off-main where practical; pure decoding is in ControlProtocol.
@MainActor
enum ControlRouter {

    /// Main-actor phase result: either a ready response, or follow-up work
    /// the socket thread must run (disk write) before replying — callers of
    /// e.g. `marks.add` read the sidecar right after the reply, so the reply
    /// must mean "durable on disk".
    enum Phase {
        case response(ControlResponse)
        case followUp(@Sendable () -> ControlResponse)
    }

    /// Socket-thread entry point: hops to main for state, then runs any
    /// deferred disk work on the calling thread.
    nonisolated static func process(_ request: ControlRequest) -> ControlResponse {
        let phase: Phase
        if Thread.isMainThread {
            phase = MainActor.assumeIsolated { handle(request) }
        } else {
            phase = DispatchQueue.main.sync { handle(request) }
        }
        switch phase {
        case .response(let r): return r
        case .followUp(let work): return work()
        }
    }

    static func handle(_ request: ControlRequest) -> Phase {
        let id = request.id
        guard let name = ControlCommandName(rawValue: request.cmd) else {
            return .response(.failure(id: id, error: "unknown command: \(request.cmd)"))
        }
        do {
            switch try dispatch(name, request: request) {
            case .data(let data):
                return .response(.success(id: id, data: data))
            case .deferred(let work):
                return .followUp(work)
            }
        } catch let err as ControlError {
            return .response(.failure(id: id, error: err.message))
        } catch {
            return .response(.failure(id: id, error: String(describing: error)))
        }
    }

    private enum Dispatched {
        case data(JSONValue)
        case deferred(@Sendable () -> ControlResponse)
    }

    private static func dispatch(_ name: ControlCommandName,
                                 request: ControlRequest) throws -> Dispatched {
        switch name {
        case .ping:
            return .data(.object(["pong": .bool(true)]))

        case .status:
            return status(request)

        case .open:
            return try open(request)

        case .reveal:
            return try reveal(request)

        case .mode:
            return .data(try setMode(request))

        case .marksList:
            return try marksList(request)

        case .marksAdd:
            return .deferred(try marksAdd(request))

        case .diffShow:
            return try diffShow(request)

        case .workspaceAdd:
            return try workspaceAdd(request)
        }
    }

    // MARK: workspace.add (D6)

    /// Validate path off main (caller may be socket thread via deferred), mutate
    /// WorkspaceModel on main. Idempotent if already adopted.
    private static func workspaceAdd(_ request: ControlRequest) throws -> Dispatched {
        guard let path = request.argString("path"), !path.isEmpty else {
            throw ControlError("workspace.add requires path")
        }
        guard path.hasPrefix("/") else {
            throw ControlError("path must be absolute (editmdctl absolutizes from cwd)")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Disk validation deferred off main.
        return .deferred { [url] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else {
                return .failure(id: request.id, error: "not a directory: \(url.path)")
            }
            let added: Bool = DispatchQueue.main.sync {
                let before = WorkspaceModel.shared.workspaces.count
                WorkspaceModel.shared.addWorkspace(url)
                let after = WorkspaceModel.shared.workspaces.count
                return after > before
            }
            return .success(id: request.id, data: .object([
                "path": .string(url.path),
                "added": .bool(added),
                "idempotent": .bool(!added),
            ]))
        }
    }

    // MARK: status

    private static func status(_ request: ControlRequest) -> Dispatched {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let url = AppState.shared.currentURL
        let mode = UserDefaults.standard.string(forKey: "editorMode")
            ?? EditorMode.preview.rawValue
        let dirty: Bool
        if let url { dirty = DocumentRegistry.shared.isDirty(url) } else { dirty = false }

        var obj: [String: JSONValue] = [
            "app": .string("EditMD"),
            "version": .string(version),
            "build": .string(build),
            "mode": .string(mode),
            "dirty": .bool(dirty),
            "socket": .string(ControlService.shared.socketPath.path),
        ]
        if let url {
            obj["path"] = .string(url.path)
            obj["isFolder"] = .bool(AppState.isFolder(url))
        } else {
            obj["path"] = .null
            obj["untitled"] = .bool(AppState.shared.isUntitled)
            obj["welcome"] = .bool(AppState.shared.isWelcome)
        }
        if ClaudeIDEService.shared.state.port != nil {
            obj["idePort"] = .int(Int(ClaudeIDEService.shared.state.port!))
            obj["ideConnected"] = .bool(ClaudeIDEService.shared.isConnected)
        }

        if let url, url.standardizedFileURL == ReviewModel.shared.fileURL {
            obj["openMarks"] = .int(ReviewModel.shared.openCount)
            return .data(.object(obj))
        }
        guard let url else {
            obj["openMarks"] = .int(0)
            return .data(.object(obj))
        }
        // Non-active file: sidecar read happens on the socket thread, not main.
        let requestID = request.id
        let partial = obj
        return .deferred {
            var out = partial
            out["openMarks"] = .int(ReviewSidecar.loadOrEmpty(for: url).openCount)
            return .success(id: requestID, data: .object(out))
        }
    }

    // MARK: open

    private static func open(_ request: ControlRequest) throws -> Dispatched {
        guard let path = request.argString("path"), !path.isEmpty else {
            throw ControlError("open requires args.path")
        }
        let url = try resolvePath(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ControlError("file not found: \(url.path)")
        }
        AppState.shared.openInMainWindow(url)
        NSApp.activate(ignoringOtherApps: true)

        let line = request.argInt("line")
        let heading = request.argString("heading")
        var data: [String: JSONValue] = ["path": .string(url.path)]
        if let line { data["line"] = .int(line) }
        if let heading { data["heading"] = .string(heading) }

        let wantsJump = (line ?? 0) > 0 || !(heading ?? "").isEmpty
        guard wantsJump else { return .data(.object(data)) }

        // Offset math needs the content: registry buffer if open (cheap,
        // main), otherwise a disk read on the socket thread — never on main.
        let buffered = DocumentRegistry.shared.contentIfOpen(url)
        let requestID = request.id
        let payload = data
        return .deferred {
            let content = buffered ?? ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            var out = payload
            var offset: Int?
            if let line, line > 0 {
                offset = offsetOfLine(line, in: content)
            } else if let heading, !heading.isEmpty {
                offset = offsetOfHeading(heading, in: content)
            }
            if let offset {
                out["offset"] = .int(offset)
                DispatchQueue.main.async {
                    AppState.shared.requestControlJump(url: url, offset: offset)
                }
            }
            return .success(id: requestID, data: .object(out))
        }
    }

    // MARK: reveal

    private static func reveal(_ request: ControlRequest) throws -> Dispatched {
        let url: URL
        if let path = request.argString("path"), !path.isEmpty {
            url = try resolvePath(path)
            AppState.shared.openInMainWindow(url)
        } else if let current = AppState.shared.currentURL, !AppState.isFolder(current) {
            url = current
        } else {
            throw ControlError("reveal: no active file (pass args.path)")
        }
        NSApp.activate(ignoringOtherApps: true)

        let line = request.argInt("line")
        let heading = request.argString("heading")

        if (line ?? 0) <= 0, (heading ?? "").isEmpty {
            // Selection (bridge) or top — no content read needed.
            var offset = 0
            if let sel = ClaudeIDEBridge.shared.reviewSelectionSource(),
               sel.url == url.standardizedFileURL {
                offset = sel.range.location
            }
            AppState.shared.requestControlJump(url: url, offset: offset)
            return .data(.object([
                "path": .string(url.path),
                "offset": .int(offset),
            ]))
        }

        // --line / --heading need the content: buffer on main, disk off main.
        let buffered = DocumentRegistry.shared.contentIfOpen(url)
        let requestID = request.id
        return .deferred {
            let content = buffered ?? ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            let offset: Int
            if let line, line > 0 {
                offset = offsetOfLine(line, in: content) ?? 0
            } else if let heading, !heading.isEmpty {
                guard let hOff = offsetOfHeading(heading, in: content) else {
                    return .failure(id: requestID, error: "heading not found: \(heading)")
                }
                offset = hOff
            } else {
                offset = 0
            }
            DispatchQueue.main.async {
                AppState.shared.requestControlJump(url: url, offset: offset)
            }
            return .success(id: requestID, data: .object([
                "path": .string(url.path),
                "offset": .int(offset),
            ]))
        }
    }

    // MARK: mode

    private static func setMode(_ request: ControlRequest) throws -> JSONValue {
        guard let raw = request.argString("mode") ?? request.argString("value"),
              let mode = EditorMode(rawValue: raw.lowercased()) else {
            throw ControlError("mode requires args.mode = source|visual|preview")
        }
        // ContentView's @AppStorage("editorMode") observes UserDefaults itself.
        UserDefaults.standard.set(mode.rawValue, forKey: "editorMode")
        return .object(["mode": .string(mode.rawValue)])
    }

    // MARK: marks

    private static func marksList(_ request: ControlRequest) throws -> Dispatched {
        let url = try fileURL(for: request)
        let openOnly = request.argBool("open") ?? true
        let requestID = request.id
        // Right after a file switch the model's doc is an empty placeholder
        // until the async reload lands — reading it here returned count: 0 for
        // a sidecar with marks. Wait out the pipeline for the active file,
        // then read disk truth; for other files disk is the only truth anyway.
        let isActive = url.standardizedFileURL == ReviewModel.shared.fileURL
        return .deferred {
            if isActive {
                let sem = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    await ReviewModel.shared.flushPipeline()
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 15)
            }
            let doc = ReviewSidecar.loadOrEmpty(for: url)
            return .success(id: requestID,
                            data: marksPayload(doc: doc, url: url, openOnly: openOnly))
        }
    }

    nonisolated private static func marksPayload(doc: ReviewDocument, url: URL,
                                                 openOnly: Bool) -> JSONValue {
        let marks = doc.marks.filter { openOnly ? $0.isOpen : true }
        let arr: [JSONValue] = marks.map { m in
            var o: [String: JSONValue] = [
                "id": .string(m.id),
                "type": .string(m.type),
                "status": .string(m.statusOrOpen),
            ]
            if let q = m.quote { o["quote"] = .string(q) }
            if let n = m.note { o["note"] = .string(n) }
            if let s = m.start { o["start"] = .int(s) }
            if let r = m.replacement { o["replacement"] = .string(r) }
            return .object(o)
        }
        return .object([
            "path": .string(url.path),
            "rev": .int(doc.rev),
            "count": .int(arr.count),
            "marks": .array(arr),
        ])
    }

    /// Both branches defer the actual sidecar write to the socket thread and
    /// reply only once it is durable — the very next CLI call may read the
    /// sidecar (`.smotr-queue.json` flow) and must see the new mark.
    private static func marksAdd(_ request: ControlRequest)
        throws -> @Sendable () -> ControlResponse {
        let url = try fileURL(for: request)
        // Ensure ReviewModel is pointed at this file when it's the main window.
        if AppState.shared.currentURL?.standardizedFileURL == url.standardizedFileURL {
            ReviewModel.shared.setActiveFile(url, text: content(of: url))
        }

        let typeRaw = request.argString("type") ?? "comment"
        guard let type = ReviewMarkType(rawValue: typeRaw), type != .suggest else {
            throw ControlError("marks.add: type must be question|fix|rewrite|cut|keep|comment")
        }
        let note = request.argString("note") ?? ""

        let quote: String
        let prefix: String
        let start: Int

        if let q = request.argString("quote"), !q.isEmpty {
            quote = q
            prefix = request.argString("prefix") ?? ""
            start = request.argInt("start") ?? 0
        } else if let sel = ClaudeIDEBridge.shared.reviewSelectionSource(),
                  sel.url.standardizedFileURL == url.standardizedFileURL,
                  let r = Range(sel.range, in: sel.markdown) {
            let a = ReviewSidecar.captureAnchor(in: sel.markdown, range: r)
            quote = a.quote
            prefix = a.prefix
            start = a.start
        } else {
            throw ControlError("marks.add: no selection and no args.quote")
        }

        let requestID = request.id
        let path = url.path
        let typeValue = type.rawValue

        // Always write via ReviewModel when it's the active file (rev-guard +
        // UI). The follow-up blocks the socket thread on the model's pipeline
        // so the reply means "on disk".
        if ReviewModel.shared.fileURL == url.standardizedFileURL {
            let anchor = ReviewModel.CapturedAnchor(quote: quote, prefix: prefix, start: start)
            let id = ReviewModel.shared.addMark(anchor: anchor, type: type, note: note)
            return {
                let sem = DispatchSemaphore(value: 0)
                let revBox = OSAllocatedUnfairLock(initialState: 0)
                Task { @MainActor in
                    await ReviewModel.shared.flushPipeline()
                    let rev = ReviewModel.shared.lastKnownRev
                    revBox.withLock { $0 = rev }
                    sem.signal()
                }
                // Bounded: a hung disk must not pin this client thread forever
                // (the mark is still queued in the model's pipeline).
                if sem.wait(timeout: .now() + 15) == .timedOut {
                    return .failure(id: requestID,
                                    error: "marks.add: sidecar write timed out")
                }
                return .success(id: requestID, data: .object([
                    "path": .string(path),
                    "id": .string(id),
                    "type": .string(typeValue),
                    "quote": .string(quote),
                    "rev": .int(revBox.withLock { $0 }),
                ]))
            }
        }

        // File not active in ReviewModel — write the sidecar directly, off main.
        let mark = ReviewMark(type: type, quote: quote, prefix: prefix, start: start, note: note)
        return {
            do {
                var doc = ReviewSidecar.loadOrEmpty(for: url)
                let baseRev = doc.rev
                doc.upsert(mark)
                let written = try ReviewSidecar.save(doc, for: url, baseRev: baseRev)
                return .success(id: requestID, data: .object([
                    "path": .string(path),
                    "id": .string(mark.id),
                    "type": .string(typeValue),
                    "quote": .string(quote),
                    "rev": .int(written.rev),
                ]))
            } catch {
                return .failure(id: requestID,
                                error: "marks.add write failed: \(error)")
            }
        }
    }

    // MARK: diff

    /// The diff itself (disk read + full lineDiff) runs on the socket thread —
    /// a multi-MB buffer or a dead network mount must not beachball the app
    /// (v35.3 invariant: full line-diffs never run on main).
    private static func diffShow(_ request: ControlRequest) throws -> Dispatched {
        let url = try fileURL(for: request)
        let buffered = DocumentRegistry.shared.contentIfOpen(url)
        let requestID = request.id
        return .deferred {
            let disk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let buffer = buffered ?? disk
            if buffer == disk {
                return .success(id: requestID, data: .object([
                    "path": .string(url.path),
                    "dirty": .bool(false),
                    "diff": .string(""),
                    "message": .string("no changes vs disk"),
                ]))
            }
            let unified = formatUnifiedDiff(old: disk, new: buffer,
                                            oldName: url.lastPathComponent + " (disk)",
                                            newName: url.lastPathComponent + " (buffer)")
            return .success(id: requestID, data: .object([
                "path": .string(url.path),
                "dirty": .bool(true),
                "diff": .string(unified),
            ]))
        }
    }

    // MARK: Helpers

    private static func fileURL(for request: ControlRequest) throws -> URL {
        if let path = request.argString("path"), !path.isEmpty {
            let url = try resolvePath(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ControlError("file not found: \(url.path)")
            }
            return url
        }
        guard let url = AppState.shared.currentURL, !AppState.isFolder(url) else {
            throw ControlError("no active file (pass args.path)")
        }
        return url
    }

    /// Absolute paths only: the app's own cwd is "/" under Finder, so
    /// resolving a caller-relative path here silently targets the wrong file.
    /// `editmdctl` absolutizes against the caller's cwd before sending.
    private static func resolvePath(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ControlError(
                "relative path \"\(path)\" would resolve against the app, not your shell — pass an absolute path")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func content(of url: URL) -> String {
        if let open = DocumentRegistry.shared.contentIfOpen(url) { return open }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 1-based line → UTF-16 offset of line start.
    nonisolated private static func offsetOfLine(_ line: Int, in text: String) -> Int? {
        guard line >= 1 else { return nil }
        let ns = text as NSString
        if line == 1 { return 0 }
        var current = 1
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == 0x0A {
                current += 1
                if current == line { return i + 1 }
            }
            i += 1
        }
        return nil
    }

    nonisolated private static func offsetOfHeading(_ title: String, in text: String) -> Int? {
        let items = markdownOutline(text)
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Exact, then case-insensitive contains.
        if let hit = items.first(where: { $0.title == needle }) {
            return hit.markdownOffset
        }
        if let hit = items.first(where: {
            $0.title.localizedCaseInsensitiveContains(needle)
        }) {
            return hit.markdownOffset
        }
        return nil
    }
}

struct ControlError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension Notification.Name {
    /// Control channel wants the editor to jump to a markdown offset. The
    /// payload lives in `AppState.shared` (pending jump, consumed by the main
    /// window when the target file is mounted) — the notification is only a
    /// nudge for the already-mounted case.
    static let editMDControlJump = Notification.Name("editmd.control.jump")
}

// MARK: - Unified diff helper

func formatUnifiedDiff(old: String, new: String, oldName: String, newName: String) -> String {
    let result = lineDiff(before: old, after: new)
    var out = "--- \(oldName)\n+++ \(newName)\n"
    for line in result.lines {
        switch line.kind {
        case .same: out += " \(line.text)\n"
        case .insert: out += "+\(line.text)\n"
        case .delete: out += "-\(line.text)\n"
        }
    }
    return out
}
