import XCTest
@testable import EditMD

final class FileHistoryGitTests: XCTestCase {

    func testParseBasicLog() {
        // Five NUL-separated fields per record (trailing NUL after subject).
        let out = [
            "aabbccddeeff00112233445566778899aabbccdd",
            "aabbccd",
            "Ada Lovelace",
            "2024-06-01T12:00:00Z",
            "Initial note",
            "",
            "11223344556677889900aabbccddeeff00112233",
            "1122334",
            "Grace Hopper",
            "2024-06-02T15:30:00+00:00",
            "Fix typo | carefully",
            "",
        ].joined(separator: "\0")
        let entries = parseGitFileHistoryLog(out)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].shortHash, "aabbccd")
        XCTAssertEqual(entries[0].author, "Ada Lovelace")
        XCTAssertEqual(entries[0].subject, "Initial note")
        XCTAssertEqual(entries[1].subject, "Fix typo | carefully")
        XCTAssertEqual(entries[1].author, "Grace Hopper")
    }

    func testParseSubjectWithNewlinesTakesFirstLine() {
        let out = [
            "abcdef0123456789abcdef0123456789abcdef01",
            "abcdef0",
            "Author",
            "2024-01-01T00:00:00Z",
            "Line one\nLine two still in field",
            "",
        ].joined(separator: "\0")
        let entries = parseGitFileHistoryLog(out)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].subject, "Line one")
    }

    func testParseEmpty() {
        XCTAssertTrue(parseGitFileHistoryLog("").isEmpty)
    }

    func testParseSkipsMalformedHash() {
        let out = [
            "not-a-hash",
            "short",
            "A",
            "2024-01-01T00:00:00Z",
            "Bad",
            "",
            "abcdef0123456789abcdef0123456789abcdef01",
            "abcdef0",
            "B",
            "2024-01-02T00:00:00Z",
            "Good",
            "",
        ].joined(separator: "\0")
        let entries = parseGitFileHistoryLog(out)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].subject, "Good")
    }

    func testParseRespectsMaxCount() {
        var parts: [String] = []
        for i in 0..<10 {
            let h = String(format: "%040d", i)
            parts += [h, String(h.prefix(7)), "A", "2024-01-01T00:00:00Z", "m\(i)", ""]
        }
        let entries = parseGitFileHistoryLog(parts.joined(separator: "\0"), maxCount: 3)
        XCTAssertEqual(entries.count, 3)
    }
}
