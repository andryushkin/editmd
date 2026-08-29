import Foundation

// Queue + headless agent trigger for review marks — mirrors smotr's ➤ button:
// snapshot open marks under the workspace into `.smotr-queue.json`
// (`{created, count, marks:[{file, kind, …mark}]}`), then optionally spawn the
// configured harness (docs/review.md § Agent handoff). Queue IO is pure
// Foundation; Process spawn lives in `ReviewAgentRunner` (@MainActor façade,
// Process off-main).

// MARK: - Queue snapshot

enum ReviewQueue {

    static let fileName = ".smotr-queue.json"
    static let agentLogName = ".smotr-agent.log"
    /// Default argv when Settings ▸ auto-spawn is on (overridable via env
    /// `EDITMD_AGENT_CMD`, matching smotr's `SMOTR_AGENT_CMD` test hook).
    static let defaultAgentCommand = ["claude", "-p", "/smotr -pr"]

    struct Snapshot: Equatable {
        var created: Int64
        var count: Int
        /// Each entry is a mark object with injected `file` + `kind` keys.
        var marks: [[String: JSONValue]]
    }

    struct BuildResult: Equatable {
        var root: URL
        var count: Int
        /// Absolute path of the queue file (may have been deleted when empty).
        var queueURL: URL
        var wroteFile: Bool
    }

    // MARK: Paths

    static func queueURL(in root: URL) -> URL {
        root.appendingPathComponent(fileName)
    }

    static func agentLogURL(in root: URL) -> URL {
        root.appendingPathComponent(agentLogName)
    }

    // MARK: Collect open marks under a workspace root

    /// Walks `root` for `*.review.json` sidecars (skipping hidden dirs) and
    /// returns open marks with paths relative to `root`. Pure disk IO — call
    /// off the main actor.
    static func collectOpenMarks(in root: URL) -> [(file: String, kind: String, mark: ReviewMark)] {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [(String, String, ReviewMark)] = []
        for case let url as URL in enumerator {
            // Skip heavy/irrelevant trees early.
            if url.hasDirectoryPath {
                let name = url.lastPathComponent
                if name == "node_modules" || name == ".git" || name == "DerivedData"
                    || name == "build" || name == ".build" {
                    enumerator.skipDescendants()
                }
                continue
            }
            let name = url.lastPathComponent
            guard name.hasSuffix(".review.json") else { continue }
            // `note.md.review.json` → artifact name `note.md`
            let artifactName = String(name.dropLast(".review.json".count))
            guard !artifactName.isEmpty else { continue }

            let parent = url.deletingLastPathComponent()
            let artifactURL = parent.appendingPathComponent(artifactName)
            let full = artifactURL.standardizedFileURL.path
            guard let rest = PathScope.relative(full, under: rootPath) else { continue }
            let rel = rest.isEmpty ? artifactName : String(rest)

            let kind = kindForArtifact(artifactName)
            let doc = ReviewSidecar.loadOrEmpty(for: artifactURL)
            for m in doc.marks where m.isOpen {
                out.append((rel, kind, m))
            }
        }

        // smotr worklist order: type priority then recency.
        out.sort { a, b in
            if a.2.priority != b.2.priority { return a.2.priority < b.2.priority }
            return (a.2.ts ?? 0) < (b.2.ts ?? 0)
        }
        return out
    }

    private static func kindForArtifact(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") { return "html" }
        return "md"
    }

    // MARK: Write / clear

    /// Builds the queue snapshot and writes (or deletes) `.smotr-queue.json`.
    /// Disk only — call off the main actor.
    static func writeQueue(in root: URL) throws -> BuildResult {
        let items = collectOpenMarks(in: root)
        let qURL = queueURL(in: root)
        if items.isEmpty {
            if FileManager.default.fileExists(atPath: qURL.path) {
                try FileManager.default.removeItem(at: qURL)
            }
            return BuildResult(root: root, count: 0, queueURL: qURL, wroteFile: false)
        }

        var markObjects: [[String: JSONValue]] = []
        markObjects.reserveCapacity(items.count)
        for (file, kind, mark) in items {
            let data = try ReviewSidecar.encodeMark(mark)
            var obj = try JSONDecoder().decode([String: JSONValue].self, from: data)
            obj["file"] = .string(file)
            obj["kind"] = .string(kind)
            markObjects.append(obj)
        }

        let snap = Snapshot(
            created: ReviewClock.nowMillis(),
            count: markObjects.count,
            marks: markObjects)
        let data = try encode(snap)
        try data.write(to: qURL, options: .atomic)
        return BuildResult(root: root, count: snap.count, queueURL: qURL, wroteFile: true)
    }

    static func encode(_ snap: Snapshot) throws -> Data {
        // JSONValue so mark entries keep free-form keys (file/kind + mark fields).
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(JSONValue.object([
            "created": .int(Int(snap.created)),
            "count": .int(snap.count),
            "marks": .array(snap.marks.map { .object($0) }),
        ]))
    }

    static func decode(_ data: Data) throws -> Snapshot {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let obj) = value else {
            throw ReviewQueueError.invalidQueue
        }
        let created: Int64
        if case .int(let i) = obj["created"] { created = Int64(i) }
        else if case .double(let d) = obj["created"] { created = Int64(d) }
        else { created = 0 }
        let count: Int
        if case .int(let i) = obj["count"] { count = i } else { count = 0 }
        var marks: [[String: JSONValue]] = []
        if case .array(let arr) = obj["marks"] {
            for item in arr {
                if case .object(let m) = item { marks.append(m) }
            }
        }
        return Snapshot(created: created, count: count, marks: marks)
    }

    /// Shell command the user can paste when auto-spawn is off.
    static func manualCommand(
        for root: URL,
        preset: AgentCommandPreset = .claude,
        custom: String = ""
    ) -> String {
        let argv = agentArgvSnapshot(preset: preset, custom: custom)
        // Keep the classic Claude line byte-stable for clipboard / tests.
        let body: String
        if argv == defaultAgentCommand {
            body = "claude -p \"/smotr -pr\""
        } else {
            body = argv.map { shellEscapeIfNeeded($0) }.joined(separator: " ")
        }
        return "cd \(shellEscape(root.path)) && \(body)"
    }

    /// Single-quote for the shell, escaping embedded single quotes. Shared
    /// with the prompt palette (AgentPromptCatalog).
    static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func shellEscapeIfNeeded(_ s: String) -> String {
        if s.contains(" ") || s.contains("\"") || s.contains("'") {
            return shellEscape(s)
        }
        return s
    }

    /// Argv for Process (snapshot settings on main first). `EDITMD_AGENT_CMD`
    /// env (test hook) wins over the preset.
    static func agentArgvSnapshot(
        preset: AgentCommandPreset,
        custom: String
    ) -> [String] {
        if let env = ProcessInfo.processInfo.environment["EDITMD_AGENT_CMD"],
           !env.isEmpty {
            return shellSplit(env)
        }
        switch preset {
        case .claude: return defaultAgentCommand
        case .codex: return AgentCommandPreset.codex.defaultArgv
        case .custom:
            let t = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? defaultAgentCommand : shellSplit(t)
        }
    }

    /// Minimal shell-ish split for the env override (no nested quotes needed
    /// for tests: `EDITMD_AGENT_CMD="/bin/echo done"`).
    private static func shellSplit(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for ch in s {
            if ch == "'" && !inDouble { inSingle.toggle(); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); continue }
            if ch == " " && !inSingle && !inDouble {
                if !current.isEmpty { parts.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

enum ReviewQueueError: Error {
    case invalidQueue
    case noWorkspace
}

// MARK: - Single-mark encode helper

extension ReviewSidecar {
    /// Encode one mark as a JSON object (for queue entries).
    static func encodeMark(_ mark: ReviewMark) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(mark)
    }
}

// MARK: - Agent runner

/// Spawns the headless Claude process for the review queue. Main-actor façade;
/// `Process` + log tail never touch the main thread.
@MainActor
final class ReviewAgentRunner: ObservableObject {

    static let shared = ReviewAgentRunner()

    enum State: Equatable {
        case idle
        case running
        case finished(exitCode: Int32)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var logTail: String = ""
    /// Workspace the current/last run used (for log path).
    @Published private(set) var root: URL?

    private var waitTask: Task<Void, Never>?
    /// Live process for Stop.
    private var runningProcess: Process?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Starts the configured agent command in `directory`. No-op if already running.
    func start(in directory: URL) {
        if isRunning { return }
        root = directory
        state = .running
        logTail = ""
        let g = EditorSettings.shared.general
        let argv = ReviewQueue.agentArgvSnapshot(
            preset: g.agentCommandPreset, custom: g.agentCustomCommand)
        guard let exe = argv.first else {
            state = .failed(String(localized: "Empty agent command — check Settings ▸ Integrations"))
            return
        }
        let args = Array(argv.dropFirst())
        let logURL = ReviewQueue.agentLogURL(in: directory)
        let queueURL = ReviewQueue.queueURL(in: directory)
        let socketPath = ControlService.shared.socketPath.path

        waitTask?.cancel()
        waitTask = Task.detached(priority: .utility) { [weak self] in
            let prepared = Self.prepareProcess(
                executable: exe, arguments: args,
                directory: directory, logURL: logURL,
                environment: [
                    "EDITMD_ENABLED": "1",
                    "EDITMD_SOCKET": socketPath,
                    "EDITMD_CONTROL_SOCK": socketPath,
                    "EDITMD_WORKSPACE": directory.path,
                    "EDITMD_QUEUE": queueURL.path,
                ])
            switch prepared {
            case .failure(let msg):
                await MainActor.run {
                    guard let self else { return }
                    self.runningProcess = nil
                    self.state = .failed(msg)
                }
                return
            case .success(let process, let logHandle):
                await MainActor.run { self?.runningProcess = process }
                let result = Self.waitProcess(process, logHandle: logHandle)
                let tail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                let clipped = String(tail.suffix(2000))
                await MainActor.run {
                    guard let self else { return }
                    // stop() cancelled us after terminate(): it already set the
                    // "stopped" state — don't overwrite it with .finished(15).
                    guard !Task.isCancelled else { return }
                    self.runningProcess = nil
                    self.logTail = clipped
                    switch result {
                    case .success(let code):
                        self.state = .finished(exitCode: code)
                        ReviewModel.shared.reload()
                    case .failure(let msg):
                        self.state = .failed(msg)
                    }
                }
            }
        }
    }

    /// Terminates a running agent process (popover Stop).
    func stop() {
        guard isRunning else { return }
        if let process = runningProcess, process.isRunning {
            process.terminate()
        }
        waitTask?.cancel()
        waitTask = nil
        runningProcess = nil
        state = .failed(String(localized: "Stopped by user"))
        let logURL = root.map { ReviewQueue.agentLogURL(in: $0) }
        if let logURL, let tail = try? String(contentsOf: logURL, encoding: .utf8) {
            logTail = String(tail.suffix(2000))
        }
    }

    func resetToIdle() {
        guard !isRunning else { return }
        state = .idle
        logTail = ""
    }

    private enum RunOutcome {
        case success(Int32)
        case failure(String)
    }

    private enum PrepareOutcome {
        case success(Process, FileHandle)
        case failure(String)
    }

    nonisolated private static func prepareProcess(
        executable: String, arguments: [String],
        directory: URL, logURL: URL,
        environment: [String: String] = [:]
    ) -> PrepareOutcome {
        let exeURL: URL
        if executable.hasPrefix("/") {
            exeURL = URL(fileURLWithPath: executable)
        } else if let resolved = resolveOnPATH(executable) {
            exeURL = resolved
        } else {
            return .failure("command not found: \(executable)")
        }

        let process = Process()
        process.executableURL = exeURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            return .failure("cannot open agent log")
        }
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
            return .success(process, logHandle)
        } catch {
            try? logHandle.close()
            return .failure(error.localizedDescription)
        }
    }

    nonisolated private static func waitProcess(
        _ process: Process, logHandle: FileHandle
    ) -> RunOutcome {
        process.waitUntilExit()
        try? logHandle.close()
        return .success(process.terminationStatus)
    }

    nonisolated private static func resolveOnPATH(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        // GUI apps often miss ~/.local/bin — prepend common user locations.
        let home = NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "\(home)/.claude/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let dirs = extras + path.split(separator: ":").map(String.init)
        let fm = FileManager.default
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
