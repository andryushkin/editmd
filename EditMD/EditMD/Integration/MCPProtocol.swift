import Foundation

// JSON-RPC 2.0 codec for the Claude Code IDE channel (v36).
//
// The IDE protocol is MCP (2025-03-26) carried over a WebSocket instead of
// stdio: the same `initialize` / `tools/list` / `tools/call` handshake, plus
// IDE→client notifications (`selection_changed`, `at_mentioned`).
//
// Pure value types, no AppKit, no actor isolation — the transport (actor) and
// the tools (main-actor facade) both speak these.

// MARK: - JSON value tree

/// Arbitrary JSON. `params`/`result` are schema-less across MCP methods, so
/// they travel as a value tree rather than as concrete Codable structs.
///
/// Integers are kept apart from doubles: a JSON-RPC `id` that arrives as `7`
/// must go back as `7`, not `7.0` — clients match responses by exact equality.
indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

extension JSONValue {

    /// Dictionary member, or nil for any non-object.
    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
}

// MARK: - Request id

/// JSON-RPC ids are numbers or strings; both must round-trip unchanged.
/// `MCPCodec` converts them to and from `JSONValue` itself.
enum RPCID: Equatable, Sendable {
    case int(Int)
    case string(String)
}

// MARK: - Messages

/// An inbound message. `id == nil` means a notification (no reply expected).
struct RPCRequest: Equatable, Sendable {
    let id: RPCID?
    let method: String
    let params: JSONValue?

    var isNotification: Bool { id == nil }
}

struct RPCError: Equatable, Sendable, Error {
    let code: Int
    let message: String

    // Standard JSON-RPC 2.0 codes.
    static let parseError = -32_700
    static let invalidRequest = -32_600
    static let methodNotFound = -32_601
    static let invalidParams = -32_602
    static let internalError = -32_603

    static func methodNotFound(_ method: String) -> RPCError {
        RPCError(code: methodNotFound, message: "Method not found: \(method)")
    }

    static func invalidParams(_ reason: String) -> RPCError {
        RPCError(code: invalidParams, message: reason)
    }
}

/// An outbound message: a response to `id`, or a server-initiated notification.
enum RPCMessage: Equatable, Sendable {
    case result(id: RPCID, JSONValue)
    case failure(id: RPCID?, RPCError)
    case notification(method: String, params: JSONValue?)
}

// MARK: - Codec

enum MCPCodec {

    /// Encoder with sorted keys so tests (and diffs of logged traffic) are
    /// stable. `withoutEscapingSlashes` keeps `file:///…` URIs readable.
    /// Shared with `MCPContent.json` — frames and embedded payloads must not
    /// diverge in formatting.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decodes one inbound frame. Batch requests are not part of the IDE
    /// protocol and are rejected as invalid.
    static func decode(_ data: Data) throws -> RPCRequest {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw RPCError(code: RPCError.parseError, message: "Invalid JSON")
        }
        guard case .object = root else {
            throw RPCError(code: RPCError.invalidRequest, message: "Request must be an object")
        }
        guard root["jsonrpc"]?.stringValue == "2.0" else {
            throw RPCError(code: RPCError.invalidRequest, message: "Missing jsonrpc: \"2.0\"")
        }
        guard let method = root["method"]?.stringValue, !method.isEmpty else {
            throw RPCError(code: RPCError.invalidRequest, message: "Missing method")
        }
        var id: RPCID?
        switch root["id"] {
        case .some(.int(let value)): id = .int(value)
        case .some(.string(let value)): id = .string(value)
        case .some(.null), .none: id = nil
        case .some:
            throw RPCError(code: RPCError.invalidRequest, message: "id must be a number or a string")
        }
        let params = root["params"]
        return RPCRequest(id: id, method: method, params: params == .null ? nil : params)
    }

    static func encode(_ message: RPCMessage) throws -> Data {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        switch message {
        case .result(let id, let value):
            object["id"] = idValue(id)
            object["result"] = value
        case .failure(let id, let error):
            object["id"] = id.map(idValue) ?? .null
            object["error"] = .object([
                "code": .int(error.code),
                "message": .string(error.message),
            ])
        case .notification(let method, let params):
            object["method"] = .string(method)
            if let params { object["params"] = params }
        }
        return try encoder.encode(JSONValue.object(object))
    }

    private static func idValue(_ id: RPCID) -> JSONValue {
        switch id {
        case .int(let v): return .int(v)
        case .string(let v): return .string(v)
        }
    }
}

// MARK: - MCP tool results

/// Every `tools/call` reply is an MCP content array whose single text item
/// carries the real payload as a JSON **string** (protocol quirk — see
/// `docs/research/claude-code-integration.md`, 2.4).
enum MCPContent {

    static func text(_ string: String) -> JSONValue {
        .object(["content": .array([.object([
            "type": .string("text"),
            "text": .string(string),
        ])])])
    }

    /// Serializes `payload` and wraps it as the text item.
    static func json(_ payload: JSONValue) -> JSONValue {
        let data = (try? MCPCodec.encoder.encode(payload)) ?? Data("{}".utf8)
        return text(String(decoding: data, as: UTF8.self))
    }
}
