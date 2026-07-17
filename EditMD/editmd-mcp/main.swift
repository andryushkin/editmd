import Foundation
import Darwin

// editmd-mcp — thin MCP stdio proxy to EditMD's control socket (plan 09 stage 6).
//
// Speaks MCP JSON-RPC 2.0 over stdin/stdout. Non-blocking tools forward to
// editmdctl/control socket. Blocking `open_diff` is not exposed here — use
// Claude Code /ide (continuation must complete exactly once in-app).
//
// Not started under XCTest. Protocol strings are English-only.

let tools: [(name: String, description: String, schema: [String: JSONValue])] = [
    ("get_active_document", "Return the active file path and mode from EditMD status", [:]),
    ("open_file", "Open a markdown file in EditMD", [
        "type": .string("object"),
        "properties": .object([
            "path": .object(["type": .string("string")]),
            "line": .object(["type": .string("integer")]),
        ]),
        "required": .array([.string("path")]),
    ]),
    ("read_review_marks", "List review marks for the active or given file", [
        "type": .string("object"),
        "properties": .object([
            "path": .object(["type": .string("string")]),
            "all": .object(["type": .string("boolean")]),
        ]),
    ]),
    ("add_review_mark", "Add a review mark from selection or quote", [
        "type": .string("object"),
        "properties": .object([
            "type": .object(["type": .string("string")]),
            "note": .object(["type": .string("string")]),
            "quote": .object(["type": .string("string")]),
            "path": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("note")]),
    ]),
    ("agent_status", "Report agent presence to the EditMD ✨ indicator", [
        "type": .string("object"),
        "properties": .object([
            "status": .object(["type": .string("string")]),
            "label": .object(["type": .string("string")]),
            "harness": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("status")]),
    ]),
]

func readLineFD() -> String? {
    var buffer = Data()
    var byte: UInt8 = 0
    while true {
        let n = read(STDIN_FILENO, &byte, 1)
        if n <= 0 { return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8) }
        if byte == 0x0A { break }
        buffer.append(byte)
    }
    return String(data: buffer, encoding: .utf8)
}

func writeLine(_ s: String) {
    var line = s
    if !line.hasSuffix("\n") { line.append("\n") }
    let data = Array(line.utf8)
    _ = data.withUnsafeBufferPointer { write(STDOUT_FILENO, $0.baseAddress!, data.count) }
}

func controlRequest(_ req: ControlRequest) throws -> ControlResponse {
    // Reuse the same client as editmdctl (inline minimal copy via process spawn).
    let ctl = ProcessInfo.processInfo.environment["EDITMDCTL"] ?? "editmdctl"
    let proc = Process()
    if ctl.hasPrefix("/") {
        proc.executableURL = URL(fileURLWithPath: ctl)
        proc.arguments = ["--json"] + controlCLIArgs(req)
    } else {
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [ctl, "--json"] + controlCLIArgs(req)
    }
    let out = Pipe()
    let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    try proc.run()
    proc.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let line = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if line.isEmpty {
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return .failure(id: req.id, error: e.isEmpty ? "editmdctl failed" : e)
    }
    return try ControlCodec.decodeResponse(line)
}

func controlCLIArgs(_ req: ControlRequest) -> [String] {
    switch req.cmd {
    case "status": return ["status"]
    case "ping": return ["ping"]
    case "open":
        var a = ["open", req.argString("path") ?? ""]
        if let line = req.argInt("line") { a += ["--line", "\(line)"] }
        return a
    case "marks.list":
        var a = ["marks", "list"]
        if let p = req.argString("path") { a += ["--path", p] }
        if req.argBool("open") == false { a.append("--all") }
        return a
    case "marks.add":
        var a = ["marks", "add",
                 "--type", req.argString("type") ?? "comment",
                 "--note", req.argString("note") ?? ""]
        if let q = req.argString("quote") { a += ["--quote", q] }
        if let p = req.argString("path") { a += ["--path", p] }
        return a
    case "agent-status":
        var a = ["agent-status", req.argString("status") ?? "idle"]
        if let l = req.argString("label") { a += ["--label", l] }
        if let h = req.argString("harness") { a += ["--harness", h] }
        return a
    default:
        return [req.cmd]
    }
}

func handle(_ msg: [String: JSONValue]) -> [String: JSONValue] {
    let id = msg["id"]
    let method = msg["method"]?.stringValue ?? ""
    func ok(_ result: JSONValue) -> [String: JSONValue] {
        var r: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "result": result,
        ]
        if let id { r["id"] = id }
        return r
    }
    func fail(_ code: Int, _ message: String) -> [String: JSONValue] {
        var r: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "error": .object([
                "code": .int(code),
                "message": .string(message),
            ]),
        ]
        if let id { r["id"] = id }
        return r
    }

    switch method {
    case "initialize":
        return ok(.object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string("editmd-mcp"),
                "version": .string("1.0.0"),
            ]),
        ]))
    case "notifications/initialized", "initialized":
        return [:] // notification — no response
    case "tools/list":
        let list: [JSONValue] = tools.map { t in
            .object([
                "name": .string(t.name),
                "description": .string(t.description),
                "inputSchema": .object(
                    t.schema.isEmpty
                    ? ["type": .string("object"), "properties": .object([:])]
                    : t.schema
                ),
            ])
        }
        return ok(.object(["tools": .array(list)]))
    case "tools/call":
        let params = msg["params"]
        let name = params?["name"]?.stringValue ?? ""
        let args = params?["arguments"]
        do {
            let result = try callTool(name, args: args)
            return ok(.object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(result),
                    ])
                ])
            ]))
        } catch {
            return fail(-32000, String(describing: error))
        }
    default:
        return fail(-32601, "Method not found: \(method)")
    }
}

func callTool(_ name: String, args: JSONValue?) throws -> String {
    switch name {
    case "get_active_document":
        let resp = try controlRequest(ControlRequest(id: "1", cmd: "status"))
        return pretty(resp)
    case "open_file":
        guard let path = args?["path"]?.stringValue else {
            throw CLIError("path required")
        }
        var map: [String: JSONValue] = ["path": .string(absolutePath(path))]
        if let line = args?["line"] {
            if case .int(let i) = line { map["line"] = .int(i) }
        }
        let resp = try controlRequest(ControlRequest(id: "1", cmd: "open", args: map))
        return pretty(resp)
    case "read_review_marks":
        var map: [String: JSONValue] = ["open": .bool(!(args?["all"]?.boolValue ?? false))]
        if let path = args?["path"]?.stringValue {
            map["path"] = .string(absolutePath(path))
        }
        let resp = try controlRequest(ControlRequest(id: "1", cmd: "marks.list", args: map))
        return pretty(resp)
    case "add_review_mark":
        var map: [String: JSONValue] = [
            "type": .string(args?["type"]?.stringValue ?? "comment"),
            "note": .string(args?["note"]?.stringValue ?? ""),
        ]
        if let q = args?["quote"]?.stringValue { map["quote"] = .string(q) }
        if let p = args?["path"]?.stringValue { map["path"] = .string(absolutePath(p)) }
        let resp = try controlRequest(ControlRequest(id: "1", cmd: "marks.add", args: map))
        return pretty(resp)
    case "agent_status":
        guard let status = args?["status"]?.stringValue else {
            throw CLIError("status required")
        }
        var map: [String: JSONValue] = ["status": .string(status)]
        if let l = args?["label"]?.stringValue { map["label"] = .string(l) }
        if let h = args?["harness"]?.stringValue { map["harness"] = .string(h) }
        let resp = try controlRequest(ControlRequest(id: "1", cmd: "agent-status", args: map))
        return pretty(resp)
    default:
        throw CLIError("unknown tool: \(name)")
    }
}

func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return expanded }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(expanded).standardizedFileURL.path
}

func pretty(_ resp: ControlResponse) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(resp), let s = String(data: data, encoding: .utf8) {
        return s
    }
    return resp.ok ? "ok" : (resp.error ?? "error")
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// Main loop
while let line = readLineFD() {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }
    guard let data = trimmed.data(using: .utf8),
          let obj = try? JSONDecoder().decode(JSONValue.self, from: data),
          case .object(let dict) = obj else {
        continue
    }
    let response = handle(dict)
    if response.isEmpty { continue }
    if let out = try? JSONEncoder().encode(JSONValue.object(response)),
       let s = String(data: out, encoding: .utf8) {
        writeLine(s)
    }
}
