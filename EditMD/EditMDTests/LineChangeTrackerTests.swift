import XCTest
@testable import EditMD

@MainActor
final class LineChangeTrackerTests: XCTestCase {

    func testDirtyLineNumbersInsert() {
        let dirty = LineChangeTracker.dirtyLineNumbers(
            baseline: "a\nb\nc\n",
            current: "a\nX\nb\nc\n")
        XCTAssertEqual(dirty, [2])
    }

    func testDirtyLineNumbersReplace() {
        let dirty = LineChangeTracker.dirtyLineNumbers(
            baseline: "hello\n",
            current: "world\n")
        XCTAssertEqual(dirty, [1])
    }

    func testDirtyLineNumbersIdentical() {
        let dirty = LineChangeTracker.dirtyLineNumbers(
            baseline: "a\nb\n",
            current: "a\nb\n")
        XCTAssertTrue(dirty.isEmpty)
    }

    // MARK: - Duplicate-line insertion (caret disambiguation)

    /// Inserting a line identical to a neighbour: without the caret the line
    /// diff attributes the new line to the *later* equal line, marking an
    /// untouched one. Regression guard for the reported "green mark on a line I
    /// didn't change" bug.
    func testDuplicateInsertWithoutCaretMarksTrailingLine() {
        let dirty = LineChangeTracker.dirtyLineNumbers(
            baseline: "a\nb\nc\n",
            current: "a\nb\nb\nc\n")
        XCTAssertEqual(dirty, [3])  // documented fallback when caret unknown
    }

    func testDuplicateInsertCaretPinsEditedLine() {
        // User typed the new "b" on line 2 → line 2 is dirty, not the old line 3.
        let dirty = LineChangeTracker.dirtyLineNumbers(
            baseline: "a\nb\nc\n",
            current: "a\nb\nb\nc\n",
            caretLine: 2)
        XCTAssertEqual(dirty, [2])
    }

    func testDuplicateAppendCaretOnLastLine() {
        // Appending a third identical item with the caret on the new last line.
        let dirty = LineChangeTracker.dirtyLineNumbers(
            baseline: "- x\n- x\n",
            current: "- x\n- x\n- x\n",
            caretLine: 3)
        XCTAssertEqual(dirty, [3])
    }

    func testCaretDoesNotOverrideDistinctChange() {
        // A distinct (non-duplicate) insertion is never re-pointed by the caret.
        let dirty = LineChangeTracker.dirtyLineNumbers(
            baseline: "| x |\n| x |\n",
            current: "| x |\n| new |\n| x |\n",
            caretLine: 1)
        XCTAssertEqual(dirty, [2])
    }

    func testCaretDoesNotOvermarkMultiRegionEdit() {
        // Two separate changes with an untouched line between must stay two marks.
        let dirty = LineChangeTracker.dirtyLineNumbers(
            baseline: "a\nb\nc\n",
            current: "X\nb\nY\n",
            caretLine: 3)
        XCTAssertEqual(dirty, [1, 3])
    }

    func testTrackerBaselineAndEdit() {
        let t = LineChangeTracker.shared
        let url = URL(fileURLWithPath: "/tmp/editmd-line-tracker-test-\(UUID().uuidString).md")
        t.noteBaseline(url: url, content: "one\ntwo\n")
        XCTAssertTrue(t.dirtyLines(for: url).isEmpty)
        t.noteContent(url: url, content: "one\ntwo\nthree\n")
        XCTAssertEqual(t.dirtyLines(for: url), [3])
        t.noteBaseline(url: url, content: "one\ntwo\nthree\n")
        XCTAssertTrue(t.dirtyLines(for: url).isEmpty)
        t.forget(url: url)
    }

    func testDisplayToSourceLineMap() {
        // "# A\n\npara\n" — para starts at line 3
        let md = "# A\n\npara\n"
        let ranges = [
            NSRange(location: 0, length: 4),   // "# A\n"
            NSRange(location: 4, length: 1),   // "\n"
            NSRange(location: 5, length: 5),   // "para\n"
        ]
        let map = displayToSourceLineMap(paragraphRanges: ranges, markdown: md)
        XCTAssertEqual(map, [1, 2, 3])
    }

    func testSourceLineNumberAt() {
        let md = "a\nb\nc"
        XCTAssertEqual(sourceLineNumber(at: 0, in: md), 1)
        XCTAssertEqual(sourceLineNumber(at: 2, in: md), 2)  // 'b'
        XCTAssertEqual(sourceLineNumber(at: 4, in: md), 3)  // 'c'
    }
}
