import XCTest
@testable import EditMD

/// The Visual gutter maps display paragraphs to SOURCE line numbers. For a
/// freshly loaded file the serialize-based map is wrong whenever the document
/// is not in the editor's normal form (lazy quote continuations collapse on
/// serialize), so the renderer reports exact source offsets instead.
final class VisualGutterSourceLineTests: XCTestCase {

    private func sourceLines(_ md: String) -> [Int] {
        let rendered = renderMarkdownToAttributedDetailed(md)
        return displayToSourceLineMap(
            paragraphRanges: rendered.paragraphSourceStarts.map {
                NSRange(location: $0, length: 0)
            },
            markdown: md)
    }

    func testLazyQuoteContinuationsKeepExactSourceLines() {
        let md = """
        ## Цитаты

        > Простая цитата.

        > Многострочная: первый абзац.
        > Второй абзац той же цитаты.

        > Внешняя.
        > > Вложенная.
        > Возврат на первый уровень.

        > [!NOTE]
        > Заметка.
        """
        // Display paragraphs: heading, quote, merged quote, outer quote,
        // merged nested quote, callout marker+text (one paragraph).
        XCTAssertEqual(sourceLines(md), [1, 3, 5, 8, 9, 12])
    }

    func testFrontmatterKeepsSourceLines() {
        let md = """
        ---
        title: t
        ---

        # Заголовок

        Абзац.
        """
        XCTAssertEqual(sourceLines(md), [5, 7])
    }

    func testMultiLineListItemKeepsFollowingLines() {
        let md = """
        - Пункт с продолжением
          на второй строке.
        - Второй пункт.

        Абзац после списка.
        """
        let lines = sourceLines(md)
        // Merged first item starts at 1, second item at 3, paragraph at 5.
        XCTAssertEqual(lines.first, 1)
        XCTAssertTrue(lines.contains(3))
        XCTAssertEqual(lines.last, 5)
    }
}

/// Which hard line the caret belongs to, for the current-line band and the
/// emphasized line number (Source).
final class GutterCurrentLineTests: XCTestCase {

    private func holds(_ text: String, caret: Int, lineAt probe: Int) -> Bool {
        let ns = text as NSString
        let line = gutterCaretLineRange(in: ns, caret: probe)
        return gutterLineHoldsCaret(
            caret, lineRange: line,
            lineEndsWithNewline: gutterLineEndsWithNewline(in: ns, lineRange: line))
    }

    func testCaretInsideLine() {
        let text = "abc\ndef\nghi"
        XCTAssertTrue(holds(text, caret: 5, lineAt: 5))
        XCTAssertFalse(holds(text, caret: 5, lineAt: 0))
    }

    /// The caret sits after the last character far more often than inside the
    /// line. On a line that ends in a newline that offset is already the next
    /// line's first position; on the last line (no newline) it is not.
    func testCaretAtLineEnd() {
        let text = "abc\ndef"
        XCTAssertTrue(holds(text, caret: 3, lineAt: 0))   // "abc|\n"
        XCTAssertFalse(holds(text, caret: 4, lineAt: 0))  // start of "def"
        XCTAssertTrue(holds(text, caret: 4, lineAt: 4))
        XCTAssertTrue(holds(text, caret: 7, lineAt: 4))   // end of document
    }

    /// A document ending in a newline really has one more, empty, line — the
    /// caret parked there must not light up the line above.
    func testCaretOnTrailingEmptyLine() {
        let text = "abc\n"
        let ns = text as NSString
        XCTAssertEqual(gutterCaretLineRange(in: ns, caret: 4),
                       NSRange(location: 4, length: 0))
        XCTAssertFalse(holds(text, caret: 4, lineAt: 0))
        XCTAssertTrue(holds(text, caret: 4, lineAt: 4))
    }

    func testEmptyDocument() {
        let ns = "" as NSString
        XCTAssertEqual(gutterCaretLineRange(in: ns, caret: 0),
                       NSRange(location: 0, length: 0))
        XCTAssertTrue(holds("", caret: 0, lineAt: 0))
    }

    /// Caret beyond the text (stale offset after an external edit) clamps
    /// instead of trapping.
    func testCaretPastEndClamps() {
        let ns = "abc" as NSString
        XCTAssertEqual(gutterCaretLineRange(in: ns, caret: 99),
                       NSRange(location: 0, length: 3))
    }

    func testCaretAtDocumentStart() {
        let text = "abc\ndef"
        XCTAssertTrue(holds(text, caret: 0, lineAt: 0))
        XCTAssertFalse(holds(text, caret: 0, lineAt: 4))
    }

    /// A document that is nothing but a newline has two lines, and the caret
    /// can sit on either.
    func testLoneNewline() {
        let text = "\n"
        let ns = text as NSString
        XCTAssertEqual(gutterCaretLineRange(in: ns, caret: 0),
                       NSRange(location: 0, length: 1))
        XCTAssertEqual(gutterCaretLineRange(in: ns, caret: 1),
                       NSRange(location: 1, length: 0))
        XCTAssertTrue(holds(text, caret: 0, lineAt: 0))
        XCTAssertFalse(holds(text, caret: 1, lineAt: 0))
        XCTAssertTrue(holds(text, caret: 1, lineAt: 1))
    }

    /// Blank line between two paragraphs — the empty middle line owns its
    /// caret, neither neighbour does.
    func testCaretOnBlankMiddleLine() {
        let text = "a\n\nb"          // lines: {0,2} "a\n", {2,1} "\n", {3,1} "b"
        let ns = text as NSString
        XCTAssertEqual(gutterCaretLineRange(in: ns, caret: 2),
                       NSRange(location: 2, length: 1))
        XCTAssertTrue(holds(text, caret: 2, lineAt: 2))
        XCTAssertFalse(holds(text, caret: 2, lineAt: 0))
        XCTAssertFalse(holds(text, caret: 2, lineAt: 3))
    }

    /// Number emphasis follows the band: a ranged selection emphasizes nothing,
    /// so a multi-line selection cannot light up its anchor's number alone.
    func testEmphasisOffset() {
        XCTAssertEqual(gutterEmphasisOffset(selection: NSRange(location: 7, length: 0),
                                            enabled: true), 7)
        XCTAssertNil(gutterEmphasisOffset(selection: NSRange(location: 7, length: 12),
                                          enabled: true))
        XCTAssertNil(gutterEmphasisOffset(selection: NSRange(location: 7, length: 0),
                                          enabled: false))
    }
}
