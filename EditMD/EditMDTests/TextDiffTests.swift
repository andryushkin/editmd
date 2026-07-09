import XCTest
@testable import EditMD

final class TextDiffTests: XCTestCase {

    func testIdentical() {
        let r = lineDiff(before: "a\nb\n", after: "a\nb\n")
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.lines.count, 3) // a, b, trailing empty from final \n
        XCTAssertTrue(r.lines.allSatisfy { $0.kind == .same })
    }

    func testInsertLine() {
        let r = lineDiff(before: "a\nc\n", after: "a\nb\nc\n")
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 0)
        let inserts = r.lines.filter { $0.kind == .insert }
        XCTAssertEqual(inserts.map(\.text), ["b"])
    }

    func testDeleteLine() {
        let r = lineDiff(before: "a\nb\nc\n", after: "a\nc\n")
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.removed, 1)
        let deletes = r.lines.filter { $0.kind == .delete }
        XCTAssertEqual(deletes.map(\.text), ["b"])
    }

    func testReplaceLine() {
        let r = lineDiff(before: "- [ ] one\n", after: "- [x] one\n")
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 1)
        XCTAssertTrue(r.lines.contains { $0.kind == .delete && $0.text.contains("[ ]") })
        XCTAssertTrue(r.lines.contains { $0.kind == .insert && $0.text.contains("[x]") })
    }

    func testSplitKeepsEmpty() {
        XCTAssertEqual(splitDiffLines(""), [""])
        XCTAssertEqual(splitDiffLines("a"), ["a"])
        XCTAssertEqual(splitDiffLines("a\n"), ["a", ""])
        XCTAssertEqual(splitDiffLines("a\nb"), ["a", "b"])
    }

    func testLineNumbers() {
        let r = lineDiff(before: "a\nb\n", after: "a\nx\nb\n")
        let insert = r.lines.first { $0.kind == .insert }
        XCTAssertEqual(insert?.text, "x")
        XCTAssertNil(insert?.oldNumber)
        XCTAssertEqual(insert?.newNumber, 2)
    }
}
