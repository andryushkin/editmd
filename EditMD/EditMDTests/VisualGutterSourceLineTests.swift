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
