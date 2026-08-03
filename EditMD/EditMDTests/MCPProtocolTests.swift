import XCTest
@testable import EditMD

/// The JSON-RPC codec is the only thing between the CLI's bytes
/// and our tool handlers. Ids must round-trip by exact type, notifications must
/// stay unanswered, and malformed frames must produce protocol errors rather
/// than crashes.
final class MCPProtocolTests: XCTestCase {

    private func json(_ message: RPCMessage) throws -> [String: Any] {
        let data = try MCPCodec.encode(message)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Decoding

    func testDecodeRequestWithIntId() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8)
        let request = try MCPCodec.decode(data)
        XCTAssertEqual(request.id, .int(7))
        XCTAssertEqual(request.method, "tools/list")
        XCTAssertNil(request.params)
        XCTAssertFalse(request.isNotification)
    }

    func testDecodeRequestWithStringIdAndParams() throws {
        let data = Data(#"""
        {"jsonrpc":"2.0","id":"abc","method":"tools/call",
         "params":{"name":"openFile","arguments":{"filePath":"/a/b.md","preview":true}}}
        """#.utf8)
        let request = try MCPCodec.decode(data)
        XCTAssertEqual(request.id, .string("abc"))
        XCTAssertEqual(request.params?["name"]?.stringValue, "openFile")
        XCTAssertEqual(request.params?["arguments"]?["filePath"]?.stringValue, "/a/b.md")
        XCTAssertEqual(request.params?["arguments"]?["preview"]?.boolValue, true)
    }

    func testDecodeNotificationHasNoId() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"initialized"}"#.utf8)
        let request = try MCPCodec.decode(data)
        XCTAssertNil(request.id)
        XCTAssertTrue(request.isNotification)
    }

    /// `"id": null` is a notification, not an id.
    func testDecodeNullIdIsNotification() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#.utf8)
        XCTAssertTrue(try MCPCodec.decode(data).isNotification)
    }

    func testDecodeRejectsInvalidJSON() {
        XCTAssertThrowsError(try MCPCodec.decode(Data("{not json".utf8))) { error in
            XCTAssertEqual((error as? RPCError)?.code, RPCError.parseError)
        }
    }

    func testDecodeRejectsMissingJSONRPCVersion() {
        XCTAssertThrowsError(try MCPCodec.decode(Data(#"{"id":1,"method":"ping"}"#.utf8))) { error in
            XCTAssertEqual((error as? RPCError)?.code, RPCError.invalidRequest)
        }
    }

    func testDecodeRejectsMissingMethod() {
        XCTAssertThrowsError(try MCPCodec.decode(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))) { error in
            XCTAssertEqual((error as? RPCError)?.code, RPCError.invalidRequest)
        }
    }

    // MARK: - Encoding

    /// An integer id must not come back as `7.0` — clients match on equality.
    func testEncodeResultPreservesIntId() throws {
        let object = try json(.result(id: .int(7), .object(["ok": .bool(true)])))
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object))
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, true)
    }

    func testEncodeResultPreservesStringId() throws {
        let object = try json(.result(id: .string("abc"), .null))
        XCTAssertEqual(object["id"] as? String, "abc")
        XCTAssertTrue(object["result"] is NSNull)
    }

    func testEncodeErrorUsesNullIdWhenUnknown() throws {
        let object = try json(.failure(id: nil, .methodNotFound("nope")))
        XCTAssertTrue(object["id"] is NSNull)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, RPCError.methodNotFound)
        XCTAssertEqual(error["message"] as? String, "Method not found: nope")
    }

    func testEncodeNotificationHasNoId() throws {
        let object = try json(.notification(method: "selection_changed",
                                            params: .object(["text": .string("hi")])))
        XCTAssertNil(object["id"])
        XCTAssertEqual(object["method"] as? String, "selection_changed")
    }

    /// File URIs must not be escaped to `file:\/\/\/…`.
    func testEncodeDoesNotEscapeSlashes() throws {
        let data = try MCPCodec.encode(
            .result(id: .int(1), .object(["uri": .string("file:///a/b.md")])))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("file:///a/b.md"))
    }

    // MARK: - MCP content envelope

    /// The payload is a JSON *string* inside `content[0].text` (protocol quirk).
    func testMCPContentWrapsJSONAsText() throws {
        let value = MCPContent.json(.object(["success": .bool(true), "n": .int(2)]))
        let content = try XCTUnwrap(value["content"]?.arrayValue)
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"]?.stringValue, "text")
        let text = try XCTUnwrap(content[0]["text"]?.stringValue)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["success"] as? Bool, true)
        XCTAssertEqual(decoded["n"] as? Int, 2)
    }

    func testMCPContentTextIsBare() throws {
        let value = MCPContent.text("FILE_SAVED")
        let content = try XCTUnwrap(value["content"]?.arrayValue)
        XCTAssertEqual(content[0]["text"]?.stringValue, "FILE_SAVED")
    }

    // MARK: - JSONValue round-trip

    func testJSONValueRoundTripKeepsIntegersDistinctFromDoubles() throws {
        let value = JSONValue.object([
            "i": .int(3),
            "d": .double(3.5),
            "s": .string("x"),
            "b": .bool(false),
            "n": .null,
            "a": .array([.int(1), .string("two")]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }
}
