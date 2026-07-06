import XCTest
@testable import EditMD

final class MarkdownLintTests: XCTestCase {

    private func diags(_ text: String, _ rule: LintRule) -> [LintDiagnostic] {
        lint(text).filter { $0.rule == rule }
    }

    private func applyFix(_ fix: LintFix, to text: String) -> String {
        (text as NSString).replacingCharacters(in: fix.range, with: fix.replacement)
    }

    // MARK: - Checkboxes

    func testInvalidCheckboxPlus() {
        let text = "- [+] milk"
        let found = diags(text, .invalidCheckbox)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].severity, .error)
        XCTAssertEqual(applyFix(found[0].fixes[0], to: text), "- [x] milk")
        XCTAssertEqual(applyFix(found[0].fixes[1], to: text), "- [ ] milk")
    }

    func testUppercaseCheckbox() {
        let text = "- [X] done"
        let found = diags(text, .uppercaseCheckbox)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].severity, .warning)
        XCTAssertEqual(applyFix(found[0].fixes[0], to: text), "- [x] done")
    }

    func testEmptyCheckbox() {
        let text = "- [] task"
        let found = diags(text, .emptyCheckbox)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(applyFix(found[0].fixes[0], to: text), "- [ ] task")
    }

    func testCheckboxMissingSpaceAfter() {
        let text = "- [x]done"
        let found = diags(text, .checkboxMissingSpace)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(applyFix(found[0].fixes[0], to: text), "- [x] done")
    }

    func testListMarkerMissingSpace() {
        let text = "-[ ] task"
        let found = diags(text, .listMarkerMissingSpace)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(applyFix(found[0].fixes[0], to: text), "- [ ] task")
    }

    func testValidCheckboxesProduceNoDiagnostics() {
        XCTAssertTrue(lint("- [ ] todo\n- [x] done").isEmpty)
    }

    func testOrderedTaskListInvalidCheckbox() {
        XCTAssertEqual(diags("1. [+] step", .invalidCheckbox).count, 1)
    }

    func testLinkListItemIsNotFlagged() {
        XCTAssertTrue(lint("- [Link](https://example.com)").isEmpty)
    }

    func testLongBracketContentIsNotFlagged() {
        // [ab] cannot be checkbox intent — content longer than one char.
        XCTAssertTrue(lint("- [ab] citation").isEmpty)
    }

    func testCheckboxInCodeBlockIgnored() {
        let text = "```\n- [+] not real\n```"
        XCTAssertTrue(diags(text, .invalidCheckbox).isEmpty)
    }

    // MARK: - Headings

    func testHeadingMissingSpace() {
        let text = "#Title"
        let found = diags(text, .headingMissingSpace)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(applyFix(found[0].fixes[0], to: text), "# Title")
    }

    func testValidHeadingNotFlagged() {
        XCTAssertTrue(diags("# Title\n## Sub", .headingMissingSpace).isEmpty)
    }

    func testHeadingInCodeBlockIgnored() {
        XCTAssertTrue(diags("```\n#!/bin/bash\n```", .headingMissingSpace).isEmpty)
    }

    // MARK: - Unpaired markers

    func testUnpairedBold() {
        XCTAssertEqual(diags("some **bold text", .unpairedBold).count, 1)
        XCTAssertTrue(diags("some **bold** text", .unpairedBold).isEmpty)
    }

    func testUnpairedBoldRunIsMerged() {
        let found = diags("a ****", .unpairedBold)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].range.length, 4)
    }

    func testUnpairedStrikethrough() {
        XCTAssertEqual(diags("a ~~gone", .unpairedStrikethrough).count, 1)
        XCTAssertTrue(diags("a ~~gone~~ b", .unpairedStrikethrough).isEmpty)
    }

    func testUnpairedBacktick() {
        XCTAssertEqual(diags("a ` b", .unpairedBacktick).count, 1)
        XCTAssertTrue(diags("run `cmd` now", .unpairedBacktick).isEmpty)
    }

    func testFencedBlockBackticksNotFlagged() {
        XCTAssertTrue(diags("```swift\nlet x = 1\n```", .unpairedBacktick).isEmpty)
    }

    // MARK: - Links

    func testEmptyLinkDestination() {
        XCTAssertEqual(diags("[text]()", .emptyLinkDestination).count, 1)
        XCTAssertTrue(diags("[text](https://e.com)", .emptyLinkDestination).isEmpty)
    }

    func testUnresolvedReference() {
        XCTAssertEqual(diags("see [text][missing]", .unresolvedReference).count, 1)
    }

    func testResolvedReferenceNotFlagged() {
        let text = "see [a][b]\n\n[b]: https://example.com"
        XCTAssertTrue(diags(text, .unresolvedReference).isEmpty)
    }

    func testUnclosedLink() {
        let text = "see [text](https://e.com"
        let found = diags(text, .unclosedLink)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].severity, .error)
        XCTAssertEqual(applyFix(found[0].fixes[0], to: text), "see [text](https://e.com)")
    }

    // MARK: - Code fences

    func testUnclosedCodeFence() {
        let text = "```swift\nlet x = 1"
        let found = diags(text, .unclosedCodeFence)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(applyFix(found[0].fixes[0], to: text), "```swift\nlet x = 1\n```")
    }

    func testClosedCodeFenceNotFlagged() {
        XCTAssertTrue(diags("```swift\nlet x = 1\n```", .unclosedCodeFence).isEmpty)
    }

    // MARK: - Tables

    func testTableCellCountMismatch() {
        let text = "| a | b |\n|---|---|\n| 1 |"
        let found = diags(text, .tableCellCountMismatch)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].message.contains("1"), found[0].message)
        XCTAssertTrue(found[0].message.contains("2"), found[0].message)
    }

    func testConsistentTableNotFlagged() {
        XCTAssertTrue(diags("| a | b |\n|---|---|\n| 1 | 2 |", .tableCellCountMismatch).isEmpty)
    }

    func testTableCellCountHelper() {
        XCTAssertEqual(tableCellCount("| a | b |"), 2)
        XCTAssertEqual(tableCellCount("a | b"), 2)
        XCTAssertEqual(tableCellCount("| a \\| b |"), 1)
        XCTAssertNil(tableCellCount("plain text"))
    }

    // MARK: - General

    func testEmptyTextNoDiagnostics() {
        XCTAssertTrue(lint("").isEmpty)
    }

    func testDiagnosticsSortedByLocation() {
        let found = lint("#One\n\n- [+] two\n\n**three")
        XCTAssertEqual(found.map(\.range.location), found.map(\.range.location).sorted())
        XCTAssertEqual(found.count, 3)
    }

    func testCleanDocumentNoDiagnostics() {
        let text = """
        # Title

        Some **bold** and *italic* and `code`.

        - [ ] task one
        - [x] task two
        - plain item

        > quote

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        [link](https://example.com)
        """
        XCTAssertTrue(lint(text).isEmpty, "\(lint(text))")
    }
}
