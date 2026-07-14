import XCTest
@testable import EditMD

final class BuiltInPluginsTests: XCTestCase {
    private let frontmatter = """
    ---
    editmd:
      plugins:
        multi-checkbox:
          states:
            - marker: "-"
              label: Queued
              icon: "sf:circle"
            - marker: "?"
              label: Needs review
              icon: "emoji:❓"
            - marker: "X"
              label: Done
              icon: "sf:checkmark.circle.fill"
              strikethrough: true
    ---
    """

    func testConfigurationKeepsDeclaredOrderAndStateMetadata() throws {
        let configuration = try XCTUnwrap(
            MultiCheckboxPlugin.configuration(in: frontmatter + "\n[-] Item"))

        XCTAssertEqual(configuration.states.map(\.source), ["[-]", "[?]", "[X]"])
        XCTAssertEqual(configuration.states.map(\.label), ["Queued", "Needs review", "Done"])
        XCTAssertEqual(configuration.states[0].icon, .sfSymbol("circle"))
        XCTAssertEqual(configuration.states[1].icon, .emoji("❓"))
        XCTAssertTrue(configuration.states[2].strikethrough)
    }

    func testConfigurationAcceptsEveryMarkerUsedByPMIDDownloadList() throws {
        let markdown = """
        ---
        editmd:
          plugins:
            multi-checkbox:
              states:
                - marker: "-"
                - marker: "x"
                - marker: "+"
                - marker: "?"
                - marker: "X"
        ---
        """
        let configuration = try XCTUnwrap(MultiCheckboxPlugin.configuration(in: markdown))
        XCTAssertEqual(configuration.states.map(\.source),
                       ["[-]", "[x]", "[+]", "[?]", "[X]"])
    }

    func testActivationNeedsTwoUniqueSingleUnitMarkers() {
        let one = """
        ---
        editmd:
          plugins:
            multi-checkbox:
              states:
                - marker: "x"
        ---
        """
        let duplicates = """
        ---
        editmd:
          plugins:
            multi-checkbox:
              states:
                - marker: "x"
                - marker: "x"
        ---
        """
        XCTAssertNil(MultiCheckboxPlugin.configuration(in: one))
        XCTAssertNil(MultiCheckboxPlugin.configuration(in: duplicates))
    }

    func testTokensWorkInListsProseAndTablesButNotProtectedMarkdown() {
        let markdown = frontmatter + """

        - [-] list
        prose [?] here
        | State | Value |
        | --- | --- |
        | [X] | row |

        `[-]` [link](url) [?](url) ![?](image.png)
        <span>[X]</span>
        ```text
        [?]
        ```
        """
        let tokens = BuiltInPluginRegistry.snapshot(for: markdown).tokens

        XCTAssertEqual(tokens.map { $0.payload.state.source }, ["[-]", "[?]", "[X]", "[X]"])
        XCTAssertEqual(tokens.map(\.isListMarker), [true, false, false, false])
    }

    func testParserMaskPreservesUTF16OffsetsAndOnlyNormalizesListMarker() {
        let markdown = frontmatter + "\n- [-] list\nprose [?]"
        let snapshot = BuiltInPluginRegistry.snapshot(for: markdown)
        let masked = maskBuiltInPluginTokensForParsing(markdown, snapshot: snapshot)

        XCTAssertEqual((masked as NSString).length, (markdown as NSString).length)
        XCTAssertTrue(masked.contains("- [ ] list"), masked)
        XCTAssertTrue(masked.utf16.contains(builtInPluginSentinelUnit), masked)
    }

    func testCycleUsesFrontmatterOrderAndWraps() throws {
        var markdown = frontmatter + "\nvalue [?]"
        let offset = (markdown as NSString).range(of: "[?]").location
        markdown = try XCTUnwrap(BuiltInPluginRegistry.cycleToken(in: markdown, at: offset))
        XCTAssertTrue(markdown.hasSuffix("value [X]"), markdown)
        markdown = try XCTUnwrap(BuiltInPluginRegistry.cycleToken(in: markdown, at: offset))
        XCTAssertTrue(markdown.hasSuffix("value [-]"), markdown)
    }

    func testVisualCycleDoesNotLeakOldAttachmentOrStrike() {
        let states = [
            BuiltInPluginTokenState(source: "[X]", label: "Done",
                                    icon: .sfSymbol("xmark.circle.fill"),
                                    strikethrough: true),
            BuiltInPluginTokenState(source: "[?]", label: "Review",
                                    icon: .emoji("❓"), strikethrough: false),
        ]
        let payload = BuiltInPluginTokenPayload(pluginID: MultiCheckboxPlugin.pluginID,
                                                states: states, stateIndex: 0)
        let old = builtInPluginTokenAttributedString(payload, font: .systemFont(ofSize: 14),
                                                     textColor: .labelColor)
        let next = builtInPluginTokenAttributedString(
            payload.next, font: .systemFont(ofSize: 14), textColor: .labelColor,
            attributes: old.attributes(at: 0, effectiveRange: nil))

        XCTAssertEqual(next.string, "❓")
        XCTAssertNil(next.attribute(.attachment, at: 0, effectiveRange: nil))
        XCTAssertNil(next.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
    }

    func testSourceHighlighterAndLintUsePluginSemantics() {
        let markdown = frontmatter + "\n- [-] queued\n- [X] done"
        let pluginSpans = collectSpans(markdown).filter {
            if case .builtInPluginToken = $0.kind { return true }
            return false
        }
        XCTAssertEqual(pluginSpans.count, 2)
        XCTAssertFalse(lint(markdown).contains {
            [.invalidCheckbox, .uppercaseCheckbox, .emptyCheckbox].contains($0.rule)
        })
    }

    func testVisualRoundTripPreservesPluginTokens() {
        let markdown = frontmatter + "\n- [-] queued\n\nprose [?]\n\n| S |\n| --- |\n| [X] |"
        let attributed = renderMarkdownToAttributed(markdown)
        var payloads: [BuiltInPluginTokenPayload] = []
        attributed.enumerateAttribute(.mdBuiltInPluginToken,
                                      in: NSRange(location: 0, length: attributed.length)) {
            value, _, _ in
            if let payload = value as? BuiltInPluginTokenPayload { payloads.append(payload) }
        }

        XCTAssertEqual(payloads.map { $0.state.source }.sorted(), ["[?]", "[X]"].sorted())
        XCTAssertEqual(serializeAttributedToMarkdown(attributed),
                       frontmatter + "\n\n- [-] queued\n\nprose [?]\n\n| S |\n| --- |\n| [X] |")
    }

    func testPreviewRendersClickableTokensAndLeavesProtectedTextAlone() {
        let markdown = frontmatter + "\n- [-] queued\n\n| S |\n| --- |\n| [?] |\n\n`[X]`"
        let html = markdownHTMLBody(markdown)

        XCTAssertEqual(html.components(separatedBy: "class=\"multi-checkbox\"").count - 1, 2,
                       html)
        XCTAssertTrue(html.contains("class=\"task multi-task\""), html)
        XCTAssertTrue(html.contains(">[X]</code>"), html)
        XCTAssertTrue(html.contains("data-plugin-offset="), html)

        let page = previewHTMLPage(markdown: markdown, fontSize: 14)
        XCTAssertTrue(page.contains("hydrateBuiltInPluginTokens()"), page)
        XCTAssertTrue(page.contains("handlers.builtInPluginToggle.postMessage"), page)
    }

    func testDocumentWithoutActivationKeepsOrdinaryCheckboxes() {
        let markdown = "- [ ] open\n- [x] done"
        XCTAssertTrue(BuiltInPluginRegistry.snapshot(for: markdown).tokens.isEmpty)
        let html = markdownHTMLBody(markdown)
        XCTAssertEqual(html.components(separatedBy: "type=\"checkbox\"").count - 1, 2, html)
        XCTAssertFalse(html.contains("multi-checkbox"), html)
    }

    func testActivationDisablesUnconfiguredTwoStateCheckboxes() {
        let markdown = frontmatter + "\n- [ ] open\n- [x] done"
        let snapshot = BuiltInPluginRegistry.snapshot(for: markdown)
        XCTAssertEqual(snapshot.tokens.count, 2)
        XCTAssertTrue(snapshot.tokens.allSatisfy { !$0.payload.isInteractive })

        let html = markdownHTMLBody(markdown)
        XCTAssertFalse(html.contains("type=\"checkbox\""), html)
        XCTAssertFalse(html.contains("class=\"multi-checkbox\""), html)
        XCTAssertTrue(html.contains(">[ ]</span>"), html)
        XCTAssertTrue(html.contains(">[x]</span>"), html)
    }
}
