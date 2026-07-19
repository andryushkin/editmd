import Foundation
import Darwin

// editmdctl — thin CLI client for EditMD's control socket (v38).
//
//   editmdctl status
//   editmdctl open ~/notes/a.md --line 12
//   editmdctl open ~/notes/a.md --heading "Intro"
//   editmdctl mode preview
//   editmdctl marks list
//   editmdctl marks add --type comment --note "…"
//   editmdctl reveal --line 3
//   editmdctl diff show
//   editmdctl --json status
//
// Speaks JSON-lines to ~/Library/Application Support/EditMD/control.sock
// (or $EDITMD_CONTROL_SOCK).
//
// File is named main.swift → top-level entry (no @main attribute).

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") {
    EditMDCtl.printHelp()
    exit(args.isEmpty ? 1 : 0)
}

var jsonOut = false
var rest: [String] = []
var i = 0
while i < args.count {
    let a = args[i]
    if a == "--json" { jsonOut = true; i += 1; continue }
    if a == "--socket", i + 1 < args.count {
        setenv(ControlSocket.envOverride, args[i + 1], 1)
        i += 2
        continue
    }
    rest.append(a)
    i += 1
}
guard !rest.isEmpty else { EditMDCtl.printHelp(); exit(1) }

do {
    let request = try EditMDCtl.buildRequest(rest)
    let response = try EditMDCtl.send(request)
    if jsonOut {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(response)
        if let s = String(data: data, encoding: .utf8) { print(s) }
    } else {
        EditMDCtl.printHuman(response)
    }
    exit(response.ok ? 0 : 2)
} catch {
    fputs("editmdctl: \(error)\n", stderr)
    exit(1)
}

enum EditMDCtl {

    /// Absolutize a user-supplied path against the CALLER's cwd — the app
    /// would otherwise resolve relative paths against its own cwd ("/" for a
    /// Finder-launched app) and hit the wrong file.
    static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
            .standardizedFileURL.path
    }

    static func buildRequest(_ args: [String]) throws -> ControlRequest {
        let cmd = args[0]
        let rest = Array(args.dropFirst())

        switch cmd {
        case "ping":
            return ControlRequest(id: "1", cmd: "ping")

        case "status":
            return ControlRequest(id: "1", cmd: "status")

        case "open":
            var path: String?
            var line: Int?
            var heading: String?
            var j = 0
            while j < rest.count {
                let a = rest[j]
                if a == "--line", j + 1 < rest.count {
                    line = Int(rest[j + 1]); j += 2; continue
                }
                if a == "--heading", j + 1 < rest.count {
                    heading = rest[j + 1]; j += 2; continue
                }
                if a.hasPrefix("-") { throw CLIError("unknown flag: \(a)") }
                if path == nil { path = a; j += 1; continue }
                throw CLIError("unexpected argument: \(a)")
            }
            guard let path else { throw CLIError("open requires a path") }
            var argsMap: [String: JSONValue] = ["path": .string(absolutePath(path))]
            if let line { argsMap["line"] = .int(line) }
            if let heading { argsMap["heading"] = .string(heading) }
            return ControlRequest(id: "1", cmd: "open", args: argsMap)

        case "reveal":
            var path: String?
            var line: Int?
            var heading: String?
            var j = 0
            while j < rest.count {
                let a = rest[j]
                if a == "--line", j + 1 < rest.count {
                    line = Int(rest[j + 1]); j += 2; continue
                }
                if a == "--heading", j + 1 < rest.count {
                    heading = rest[j + 1]; j += 2; continue
                }
                if a == "--path", j + 1 < rest.count {
                    path = rest[j + 1]; j += 2; continue
                }
                if !a.hasPrefix("-"), path == nil { path = a; j += 1; continue }
                throw CLIError("unknown argument: \(a)")
            }
            var argsMap: [String: JSONValue] = [:]
            if let path { argsMap["path"] = .string(absolutePath(path)) }
            if let line { argsMap["line"] = .int(line) }
            if let heading { argsMap["heading"] = .string(heading) }
            return ControlRequest(id: "1", cmd: "reveal",
                                  args: argsMap.isEmpty ? nil : argsMap)

        case "mode":
            guard let m = rest.first else {
                throw CLIError("mode requires source|visual|preview")
            }
            return ControlRequest(id: "1", cmd: "mode",
                                  args: ["mode": .string(m)])

        case "marks":
            guard let sub = rest.first else {
                throw CLIError("marks requires list|add")
            }
            let subRest = Array(rest.dropFirst())
            if sub == "list" {
                var path: String?
                var openOnly = true
                var j = 0
                while j < subRest.count {
                    let a = subRest[j]
                    if a == "--path", j + 1 < subRest.count {
                        path = subRest[j + 1]; j += 2; continue
                    }
                    if a == "--all" { openOnly = false; j += 1; continue }
                    if !a.hasPrefix("-"), path == nil { path = a; j += 1; continue }
                    throw CLIError("unknown argument: \(a)")
                }
                var argsMap: [String: JSONValue] = ["open": .bool(openOnly)]
                if let path { argsMap["path"] = .string(absolutePath(path)) }
                return ControlRequest(id: "1", cmd: "marks.list", args: argsMap)
            }
            if sub == "add" {
                var type = "comment"
                var note = ""
                var quote: String?
                var path: String?
                var j = 0
                while j < subRest.count {
                    let a = subRest[j]
                    if a == "--type", j + 1 < subRest.count {
                        type = subRest[j + 1]; j += 2; continue
                    }
                    if a == "--note", j + 1 < subRest.count {
                        note = subRest[j + 1]; j += 2; continue
                    }
                    if a == "--quote", j + 1 < subRest.count {
                        quote = subRest[j + 1]; j += 2; continue
                    }
                    if a == "--path", j + 1 < subRest.count {
                        path = subRest[j + 1]; j += 2; continue
                    }
                    throw CLIError("unknown argument: \(a)")
                }
                var argsMap: [String: JSONValue] = [
                    "type": .string(type),
                    "note": .string(note),
                ]
                if let quote { argsMap["quote"] = .string(quote) }
                if let path { argsMap["path"] = .string(absolutePath(path)) }
                return ControlRequest(id: "1", cmd: "marks.add", args: argsMap)
            }
            throw CLIError("marks requires list|add")

        case "diff":
            guard rest.first == "show" else {
                throw CLIError("diff requires show")
            }
            var path: String?
            if rest.count > 1 {
                let a = rest[1]
                if a == "--path", rest.count > 2 { path = rest[2] }
                else if !a.hasPrefix("-") { path = a }
            }
            var argsMap: [String: JSONValue]? = nil
            if let path { argsMap = ["path": .string(absolutePath(path))] }
            return ControlRequest(id: "1", cmd: "diff.show", args: argsMap)

        case "workspace":
            guard rest.first == "add" else {
                throw CLIError("workspace requires add <path>")
            }
            guard rest.count >= 2 else { throw CLIError("workspace add requires a path") }
            let path = absolutePath(rest[1])
            return ControlRequest(id: "1", cmd: "workspace.add",
                                  args: ["path": .string(path)])

        case "links":
            guard let sub = rest.first else {
                throw CLIError("links requires outgoing|backlinks|resolve")
            }
            let subRest = Array(rest.dropFirst())
            switch sub {
            case "outgoing", "backlinks":
                var path: String?
                var j = 0
                while j < subRest.count {
                    let a = subRest[j]
                    if a == "--path", j + 1 < subRest.count {
                        path = subRest[j + 1]; j += 2; continue
                    }
                    if !a.hasPrefix("-"), path == nil { path = a; j += 1; continue }
                    throw CLIError("unknown argument: \(a)")
                }
                var argsMap: [String: JSONValue] = [:]
                if let path { argsMap["path"] = .string(absolutePath(path)) }
                return ControlRequest(id: "1", cmd: "links.\(sub)",
                                      args: argsMap.isEmpty ? nil : argsMap)
            case "resolve":
                var target: String?
                var from: String?
                var j = 0
                while j < subRest.count {
                    let a = subRest[j]
                    if a == "--from", j + 1 < subRest.count {
                        from = subRest[j + 1]; j += 2; continue
                    }
                    if !a.hasPrefix("-"), target == nil { target = a; j += 1; continue }
                    throw CLIError("unknown argument: \(a)")
                }
                guard let target else { throw CLIError("links resolve requires a target") }
                var argsMap: [String: JSONValue] = ["target": .string(target)]
                if let from { argsMap["from"] = .string(absolutePath(from)) }
                return ControlRequest(id: "1", cmd: "links.resolve", args: argsMap)
            default:
                throw CLIError("links requires outgoing|backlinks|resolve")
            }

        case "outline":
            var path: String?
            if let a = rest.first {
                if a == "--path", rest.count > 1 { path = rest[1] }
                else if !a.hasPrefix("-") { path = a }
                else { throw CLIError("unknown argument: \(a)") }
            }
            var argsMap: [String: JSONValue]? = nil
            if let path { argsMap = ["path": .string(absolutePath(path))] }
            return ControlRequest(id: "1", cmd: "outline", args: argsMap)

        case "lint":
            guard let sub = rest.first else {
                throw CLIError("lint requires workspace|file")
            }
            let subRest = Array(rest.dropFirst())
            if sub == "workspace" {
                var limit: Int?
                var j = 0
                while j < subRest.count {
                    let a = subRest[j]
                    if a == "--limit", j + 1 < subRest.count {
                        limit = Int(subRest[j + 1]); j += 2; continue
                    }
                    throw CLIError("unknown argument: \(a)")
                }
                var argsMap: [String: JSONValue]? = nil
                if let limit { argsMap = ["limit": .int(limit)] }
                return ControlRequest(id: "1", cmd: "lint.workspace", args: argsMap)
            }
            if sub == "file" {
                var path: String?
                var j = 0
                while j < subRest.count {
                    let a = subRest[j]
                    if a == "--path", j + 1 < subRest.count {
                        path = subRest[j + 1]; j += 2; continue
                    }
                    if !a.hasPrefix("-"), path == nil { path = a; j += 1; continue }
                    throw CLIError("unknown argument: \(a)")
                }
                var argsMap: [String: JSONValue]? = nil
                if let path { argsMap = ["path": .string(absolutePath(path))] }
                return ControlRequest(id: "1", cmd: "lint.file", args: argsMap)
            }
            throw CLIError("lint requires workspace|file")

        case "index":
            guard rest.first == "status" else {
                throw CLIError("index requires status")
            }
            return ControlRequest(id: "1", cmd: "index.status")

        case "tags":
            guard let sub = rest.first else {
                throw CLIError("tags requires list|files")
            }
            if sub == "list" {
                return ControlRequest(id: "1", cmd: "tags.list")
            }
            if sub == "files" {
                guard rest.count >= 2 else {
                    throw CLIError("tags files requires a tag")
                }
                return ControlRequest(id: "1", cmd: "tags.files",
                                      args: ["tag": .string(rest[1])])
            }
            throw CLIError("tags requires list|files")

        case "frontmatter":
            guard rest.first == "get" else {
                throw CLIError("frontmatter requires get")
            }
            var path: String?
            if rest.count > 1 {
                let a = rest[1]
                if a == "--path", rest.count > 2 { path = rest[2] }
                else if !a.hasPrefix("-") { path = a }
                else { throw CLIError("unknown argument: \(a)") }
            }
            var argsMap: [String: JSONValue]? = nil
            if let path { argsMap = ["path": .string(absolutePath(path))] }
            return ControlRequest(id: "1", cmd: "frontmatter.get", args: argsMap)

        case "agent-status":
            // editmdctl agent-status <idle|active|completed|blocked> [--label T] [--harness N]
            guard let state = rest.first, !state.hasPrefix("-") else {
                throw CLIError("agent-status requires idle|active|completed|blocked")
            }
            var label: String?
            var harness: String?
            var j = 1
            while j < rest.count {
                let a = rest[j]
                if a == "--label", j + 1 < rest.count {
                    label = rest[j + 1]; j += 2; continue
                }
                if a == "--harness", j + 1 < rest.count {
                    harness = rest[j + 1]; j += 2; continue
                }
                throw CLIError("unknown agent-status flag: \(a)")
            }
            var argsMap: [String: JSONValue] = ["status": .string(state)]
            if let label { argsMap["label"] = .string(label) }
            if let harness { argsMap["harness"] = .string(harness) }
            return ControlRequest(id: "1", cmd: "agent-status", args: argsMap)

        default:
            throw CLIError("unknown command: \(cmd)")
        }
    }

    static func send(_ request: ControlRequest) throws -> ControlResponse {
        let path: String
        if let env = ProcessInfo.processInfo.environment[ControlSocket.envOverride],
           !env.isEmpty {
            path = env
        } else {
            path = ControlSocket.defaultPath().path
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError("EditMD is not running (no socket at \(path))")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("socket() failed: \(errno)") }
        defer { close(fd) }
        // EPIPE (not SIGPIPE) if EditMD dies mid-exchange; bounded waits so a
        // wedged app never hangs the calling script forever.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                   socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw CLIError("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() { buf[i] = UInt8(bitPattern: b) }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            throw CLIError("connect failed (is EditMD running?): \(errno)")
        }

        let payload = try ControlCodec.encodeRequest(request)
        let bytes = Array(payload.utf8)
        var written = 0
        while written < bytes.count {
            let w = bytes.withUnsafeBufferPointer { buf in
                Darwin.write(fd, buf.baseAddress! + written, bytes.count - written)
            }
            if w <= 0 { throw CLIError("write failed") }
            written += w
        }

        // Read one response line.
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError("timed out waiting for EditMD (10s)")
                }
                throw CLIError("read failed: \(errno)")
            }
            if n == 0 { break }
            buffer.append(contentsOf: tmp[0..<n])
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer.subdata(in: 0..<nl), encoding: .utf8) ?? ""
                return try ControlCodec.decodeResponse(line)
            }
        }
        throw CLIError("no response from EditMD")
    }

    static func printHuman(_ response: ControlResponse) {
        if !response.ok {
            fputs("error: \(response.error ?? "unknown")\n", stderr)
            return
        }
        guard let data = response.data else {
            print("ok")
            return
        }
        printJSONValue(data, indent: 0)
    }

    static func printJSONValue(_ v: JSONValue, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        switch v {
        case .null: print("\(pad)null")
        case .bool(let b): print("\(pad)\(b)")
        case .int(let i): print("\(pad)\(i)")
        case .double(let d): print("\(pad)\(d)")
        case .string(let s):
            if s.contains("\n") {
                print(s)
            } else {
                print("\(pad)\(s)")
            }
        case .array(let arr):
            for (i, item) in arr.enumerated() {
                print("\(pad)[\(i)]")
                printJSONValue(item, indent: indent + 1)
            }
        case .object(let obj):
            for key in obj.keys.sorted() {
                guard let val = obj[key] else { continue }
                switch val {
                case .string(let s) where s.contains("\n"):
                    print("\(pad)\(key):")
                    print(s)
                case .object, .array:
                    print("\(pad)\(key):")
                    printJSONValue(val, indent: indent + 1)
                default:
                    let oneLine: String
                    switch val {
                    case .null: oneLine = "null"
                    case .bool(let b): oneLine = "\(b)"
                    case .int(let i): oneLine = "\(i)"
                    case .double(let d): oneLine = "\(d)"
                    case .string(let s): oneLine = s
                    default: oneLine = ""
                    }
                    print("\(pad)\(key): \(oneLine)")
                }
            }
        }
    }

    static func printHelp() {
        let sock = ControlSocket.defaultPath().path
        print("""
        editmdctl — control a running EditMD instance

        Usage:
          editmdctl [--json] [--socket PATH] <command> [args]

        Commands:
          status
          ping
          open <path> [--line N | --heading TITLE]
          reveal [--path P] [--line N | --heading TITLE]
          mode source|visual|preview
          marks list [--path P] [--all]
          agent-status <idle|active|completed|blocked> [--label T] [--harness N]

          marks add [--path P] --type TYPE --note TEXT [--quote Q]
          diff show [--path P]

        Vault graph (wikillm; answers cover the ACTIVE workspace):
          index status
          links outgoing [path]
          links backlinks [path]
          links resolve <target> [--from PATH]
          outline [path]
          lint workspace [--limit N]
          lint file [path]
          tags list
          tags files <tag>
          frontmatter get [path]

        Socket: \(sock)
        Override: --socket PATH  or  $EDITMD_CONTROL_SOCK
        """)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
