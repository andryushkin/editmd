import Foundation

// Control-channel protocol (v38, phase 3): JSON-lines over a unix domain
// socket. One request line → one response line. Shared by the app server and
// the `editmdctl` CLI (the CLI target recompiles this file).
//
// Shape:
//   → {"id":"1","cmd":"open","args":{"path":"/a.md","line":10}}
//   ← {"id":"1","ok":true,"data":{"path":"/a.md"}}
//   ← {"id":"1","ok":false,"error":"…"}

// MARK: - Request / response

struct ControlRequest: Equatable, Sendable, Codable {
    var id: String?
    var cmd: String
    var args: [String: JSONValue]?

    init(id: String? = nil, cmd: String, args: [String: JSONValue]? = nil) {
        self.id = id
        self.cmd = cmd
        self.args = args
    }

    func argString(_ key: String) -> String? { args?[key]?.stringValue }
    func argInt(_ key: String) -> Int? {
        guard let v = args?[key] else { return nil }
        if case .int(let i) = v { return i }
        if case .double(let d) = v { return Int(d) }
        if case .string(let s) = v { return Int(s) }
        return nil
    }
    func argBool(_ key: String) -> Bool? { args?[key]?.boolValue }
}

struct ControlResponse: Equatable, Sendable, Codable {
    var id: String?
    var ok: Bool
    var data: JSONValue?
    var error: String?

    static func success(id: String?, data: JSONValue? = nil) -> ControlResponse {
        ControlResponse(id: id, ok: true, data: data, error: nil)
    }
    static func failure(id: String?, error: String) -> ControlResponse {
        ControlResponse(id: id, ok: false, data: nil, error: error)
    }
}

// MARK: - Codec (one JSON object per line)

enum ControlCodec {
    static func decodeRequest(_ line: String) throws -> ControlRequest {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ControlCodecError.emptyLine }
        guard let data = trimmed.data(using: .utf8) else {
            throw ControlCodecError.invalidUTF8
        }
        return try JSONDecoder().decode(ControlRequest.self, from: data)
    }

    static func encodeResponse(_ response: ControlResponse) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(response)
        guard var s = String(data: data, encoding: .utf8) else {
            throw ControlCodecError.invalidUTF8
        }
        if !s.hasSuffix("\n") { s.append("\n") }
        return s
    }

    static func encodeRequest(_ request: ControlRequest) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(request)
        guard var s = String(data: data, encoding: .utf8) else {
            throw ControlCodecError.invalidUTF8
        }
        if !s.hasSuffix("\n") { s.append("\n") }
        return s
    }

    static func decodeResponse(_ line: String) throws -> ControlResponse {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ControlCodecError.emptyLine }
        guard let data = trimmed.data(using: .utf8) else {
            throw ControlCodecError.invalidUTF8
        }
        return try JSONDecoder().decode(ControlResponse.self, from: data)
    }
}

enum ControlCodecError: Error, Equatable {
    case emptyLine
    case invalidUTF8
}

// MARK: - Known commands

enum ControlCommandName: String, CaseIterable, Sendable {
    case ping
    case status
    case open
    case reveal
    case mode
    case marksList = "marks.list"
    case marksAdd = "marks.add"
    case diffShow = "diff.show"

    var help: String {
        switch self {
        case .ping: return "liveness check"
        case .status: return "app version, active file, mode, open marks"
        case .open: return "open <path> [--line N | --heading H]"
        case .reveal: return "jump to --line N (or current selection)"
        case .mode: return "mode source|visual|preview"
        case .marksList: return "list review marks for active (or --path) file"
        case .marksAdd: return "add a mark from selection or --quote/--note/--type"
        case .diffShow: return "unified diff of buffer vs last-saved / disk"
        }
    }
}

// MARK: - Socket path

enum ControlSocket {
    /// `~/Library/Application Support/EditMD/control.sock`
    static func defaultPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library/Application Support/EditMD", isDirectory: true)
            .appendingPathComponent("control.sock")
    }

    static let envOverride = "EDITMD_CONTROL_SOCK"
}
