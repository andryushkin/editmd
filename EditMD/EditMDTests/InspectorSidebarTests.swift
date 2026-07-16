import XCTest
@testable import EditMD

/// Unit tests for the right inspector and left-sidebar tab migration (plan 01).
final class InspectorSidebarTests: XCTestCase {

    // MARK: - sidebarTab migration after Outline moved right

    func testMigrateRetiredOutlineTab() {
        XCTAssertEqual(migrateWorkspaceSidebarTab("outline"), "files")
    }

    func testMigrateKeepsValidTabs() {
        for tab in ["files", "git", "review", "tags"] {
            XCTAssertEqual(migrateWorkspaceSidebarTab(tab), tab, tab)
        }
    }

    func testMigrateUnknownTabUnchanged() {
        // Unknown keys stay as-is; WorkspaceSidebar switch falls back to Files UI.
        XCTAssertEqual(migrateWorkspaceSidebarTab("unknown"), "unknown")
    }

    // MARK: - computeFileInfoStats

    func testStatsEmptyFile() {
        let s = computeFileInfoStats(text: "")
        XCTAssertEqual(s.words, 0)
        XCTAssertEqual(s.chars, 0)
        XCTAssertEqual(s.lines, 0)
        XCTAssertEqual(s.headings, 0)
        XCTAssertEqual(s.lineEndings, .none)
        XCTAssertFalse(s.hasTrailingNewline)
    }

    func testStatsLF() {
        let text = "hello world\n# Title\n"
        let s = computeFileInfoStats(text: text)
        // wordAndCharCount splits on whitespace: hello, world, #, Title
        XCTAssertEqual(s.words, 4)
        XCTAssertEqual(s.chars, text.count)
        XCTAssertEqual(s.lines, 2)
        XCTAssertEqual(s.headings, 1)
        XCTAssertEqual(s.lineEndings, .lf)
        XCTAssertTrue(s.hasTrailingNewline)
    }

    func testStatsCRLF() {
        let s = computeFileInfoStats(text: "one\r\ntwo\r\n")
        XCTAssertEqual(s.words, 2)
        XCTAssertEqual(s.lines, 2)
        XCTAssertEqual(s.lineEndings, .crlf)
        XCTAssertTrue(s.hasTrailingNewline)
    }

    func testStatsMixedLineEndings() {
        let s = computeFileInfoStats(text: "a\nb\r\nc")
        XCTAssertEqual(s.lineEndings, .mixed)
        XCTAssertEqual(s.lines, 3)
        XCTAssertFalse(s.hasTrailingNewline)
    }

    func testStatsNoTrailingNewline() {
        let s = computeFileInfoStats(text: "solo line")
        XCTAssertEqual(s.lines, 1)
        XCTAssertEqual(s.words, 2)
        XCTAssertEqual(s.lineEndings, .none)
        XCTAssertFalse(s.hasTrailingNewline)
    }

    func testStatsHeadingsIgnoreFence() {
        let md = """
        # Real
        ```
        # Not a heading
        ```
        ## Also
        """
        let s = computeFileInfoStats(text: md)
        XCTAssertEqual(s.headings, 2)
    }

    // MARK: - Properties tab (read-only classification surface)

    func testClassifyFeedsPropertiesPanel() {
        let doc = """
        ---
        title: Note
        tags: [a, b]
        nested:
          x: 1
        ---
        body
        """
        let fields = classifyFrontmatterFields(in: doc)
        XCTAssertEqual(fields.map(\.key), ["title", "tags", "nested"])
        XCTAssertEqual(fields[0].kind, .string)
        XCTAssertEqual(fields[1].kind, .tags)
        XCTAssertEqual(fields[2].kind, .complex)
        XCTAssertFalse(fields[2].isEditable)
        XCTAssertNotNil(fields[2].utf16Offset)
    }

    func testPropertiesOpenInSourceOffset() {
        let doc = "---\ntitle: A\nnested:\n  x: 1\n---\n"
        let offset = frontmatterFieldUTF16Offset(in: doc, key: "nested")
        XCTAssertEqual(offset, 4 + ("title: A\n" as NSString).length)
        let slice = (doc as NSString).substring(from: offset!)
        XCTAssertTrue(slice.hasPrefix("nested:"))
    }

    func testFormatByteSize() {
        XCTAssertEqual(formatByteSize(500), "500 B")
        XCTAssertEqual(formatByteSize(2048), "2.0 KB")
        XCTAssertEqual(formatByteSize(2 * 1024 * 1024), "2.0 MB")
    }

    func testLineEndingCaption() {
        XCTAssertEqual(lineEndingCaption(.lf), "LF")
        XCTAssertEqual(lineEndingCaption(.crlf), "CRLF")
        XCTAssertEqual(lineEndingCaption(.cr), "CR")
        XCTAssertEqual(lineEndingCaption(.mixed), "Mixed")
        XCTAssertEqual(lineEndingCaption(.none), "—")
    }

    func testStatsBareCR() {
        let s = computeFileInfoStats(text: "a\rb\r")
        XCTAssertEqual(s.lineEndings, .cr)
        XCTAssertTrue(s.hasTrailingNewline)
    }

    func testStatsBareCRMixedWithLF() {
        let s = computeFileInfoStats(text: "a\rb\nc")
        XCTAssertEqual(s.lineEndings, .mixed)
    }
}
