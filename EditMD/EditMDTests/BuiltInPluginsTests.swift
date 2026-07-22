import XCTest
import Testing
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

    func testConfigurationAcceptsIndentlessYAMLSequence() throws {
        let markdown = """
        ---
        editmd:
          plugins:
            multi-checkbox:
              states:
              - marker: "-"
                label: Queued
              - marker: "?"
                label: Review
        ---
        """

        let configuration = try XCTUnwrap(MultiCheckboxPlugin.configuration(in: markdown))
        XCTAssertEqual(configuration.states.map(\.source), ["[-]", "[?]"])
        XCTAssertEqual(configuration.states.map(\.label), ["Queued", "Review"])
    }

    func testActivationAcceptsOneStateButRejectsDuplicateMarkers() {
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
        XCTAssertEqual(MultiCheckboxPlugin.configuration(in: one)?.states.map(\.source), ["[x]"])
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

    func testInactiveDocumentSkipsPluginCoreParse() {
        var providerCalls = 0
        let snapshot = BuiltInPluginRegistry.snapshot(for: "- [ ] open") {
            providerCalls += 1
            return collectCoreSpans("- [ ] open")
        }

        XCTAssertTrue(snapshot.tokens.isEmpty)
        XCTAssertEqual(providerCalls, 0)
    }

    func testActiveDocumentRequestsPluginCoreParseOnce() {
        let markdown = frontmatter + "\nprose [?]"
        var providerCalls = 0
        let snapshot = BuiltInPluginRegistry.snapshot(for: markdown) {
            providerCalls += 1
            return collectCoreSpans(markdown)
        }

        XCTAssertEqual(snapshot.tokens.count, 1)
        XCTAssertEqual(providerCalls, 1)
    }

    func testParserMaskPreservesUTF16OffsetsAndOnlyNormalizesListMarker() {
        let markdown = frontmatter + "\n- [-] list\nprose [?]"
        let snapshot = BuiltInPluginRegistry.snapshot(for: markdown)
        let masked = maskBuiltInPluginTokensForParsing(markdown, snapshot: snapshot)

        XCTAssertEqual((masked as NSString).length, (markdown as NSString).length)
        XCTAssertTrue(masked.contains("- [ ] list"), masked)
        XCTAssertTrue(masked.utf16.contains(builtInPluginSentinelUnit), masked)
    }

    func testPreviewSentinelLookupRequiresExactSourceOffset() throws {
        let markdown = frontmatter + "\nfirst [?] second [X]"
        let snapshot = BuiltInPluginRegistry.snapshot(for: markdown)
        let firstOffset = (markdown as NSString).range(of: "[?]").location
        let secondOffset = (markdown as NSString).range(of: "[X]").location

        var exactCursor = BuiltInPluginSentinelCursor(tokens: snapshot.tokens)
        let exact = try XCTUnwrap(exactCursor.next(startingAt: secondOffset, maxLength: 3))
        XCTAssertEqual(exact.payload.state.source, "[X]")
        XCTAssertNil(exactCursor.next(startingAt: secondOffset - 1, maxLength: 3))

        var fallbackCursor = BuiltInPluginSentinelCursor(tokens: snapshot.tokens)
        let fallback = try XCTUnwrap(fallbackCursor.next(startingAt: nil, maxLength: 3))
        XCTAssertEqual(fallback.range.location, firstOffset)
        XCTAssertEqual(fallback.payload.state.source, "[?]")
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
        // Visual renders body only; the coordinator re-attaches frontmatter.
        XCTAssertEqual(
            composeDocumentWithFrontmatter(frontmatter,
                                           body: serializeAttributedToMarkdown(attributed)),
            frontmatter + "\n\n- [-] queued\n\nprose [?]\n\n| S |\n| --- |\n| [X] |")
    }

    func testFragmentSnapshotReusesDocumentActivationWithLocalOffsets() {
        let document = BuiltInPluginRegistry.snapshot(for: frontmatter + "\nprose [?]")
        let fragment = "| S |\n| --- |\n| [X] |"
        let snapshot = BuiltInPluginRegistry.snapshot(forFragment: fragment, in: document)

        XCTAssertEqual(snapshot.tokens.map { $0.payload.state.source }, ["[X]"])
        XCTAssertEqual(snapshot.tokens.first?.range,
                       (fragment as NSString).range(of: "[X]"))
        XCTAssertTrue(BuiltInPluginRegistry.snapshot(forFragment: fragment,
                                                     in: .empty).tokens.isEmpty)
        XCTAssertTrue(BuiltInPluginRegistry.snapshot(forFragment: "",
                                                     in: document).tokens.isEmpty)
    }

    func testTableRowDeleteRerenderKeepsPluginTokensUnescaped() throws {
        // Mirrors Visual's rebuildNativeTable pipeline: serialize the rendered
        // table → grid mutation → re-render the fragment with the document's
        // plugin snapshot → serialize. Tokens must stay verbatim, not `\[X\]`.
        let markdown = frontmatter
            + "\n| S | V |\n| --- | --- |\n| [X] | one |\n| [?] | two |"
        let serializedTable = serializeAttributedToMarkdown(
            renderMarkdownToAttributed(markdown))
        var grid = try XCTUnwrap(parseGFMTable(serializedTable))
        XCTAssertTrue(grid.deleteRow(at: 1))

        let fragment = serializeGFMTable(grid)
        let document = BuiltInPluginRegistry.snapshot(for: markdown)
        let rerendered = renderMarkdownToAttributed(
            fragment,
            pluginSnapshot: BuiltInPluginRegistry.snapshot(forFragment: fragment,
                                                           in: document))
        let serialized = serializeAttributedToMarkdown(rerendered)

        XCTAssertTrue(serialized.contains("| [X] | one |"), serialized)
        XCTAssertFalse(serialized.contains(#"\["#), serialized)
    }

    func testTokenRunSerializesThroughSFSymbolTextFallback() {
        // An unresolvable SF Symbol renders the token as its source TEXT, not
        // as an attachment. Serialization must still recognize that run as
        // the token — review follow-up (codex P1).
        let state = BuiltInPluginTokenState(source: "[X]", label: "Done",
                                            icon: .sfSymbol("no.such.symbol.zzz"),
                                            strikethrough: false)
        let payload = BuiltInPluginTokenPayload(pluginID: MultiCheckboxPlugin.pluginID,
                                                states: [state], stateIndex: 0)
        let rendered = builtInPluginTokenAttributedString(
            payload, font: .systemFont(ofSize: 14), textColor: .labelColor)
        XCTAssertEqual(rendered.string, "[X]")
        XCTAssertEqual(serializeAttributedToMarkdown(rendered), "[X]")
    }

    func testTextMergedIntoTokenRunKeepsBothTokenAndText() {
        // Typing at a paragraph start inherits the following token's
        // attribute; typing after a token inherits it too. Neither side may
        // be dropped, and U+FFFC must never leak — review follow-up (codex P2).
        let states = [BuiltInPluginTokenState(source: "[?]", label: "Review",
                                              icon: .emoji("❓"), strikethrough: false)]
        let payload = BuiltInPluginTokenPayload(pluginID: MultiCheckboxPlugin.pluginID,
                                                states: states, stateIndex: 0)
        let merged = NSMutableAttributedString(string: "abc❓xyz")
        merged.addAttribute(.mdBuiltInPluginToken, value: payload,
                            range: NSRange(location: 0, length: merged.length))
        XCTAssertEqual(serializeAttributedToMarkdown(merged), "abc[?]xyz")

        let leaked = NSMutableAttributedString(string: "no icon here\u{FFFC}")
        leaked.addAttribute(.mdBuiltInPluginToken, value: payload,
                            range: NSRange(location: 0, length: leaked.length))
        XCTAssertEqual(serializeAttributedToMarkdown(leaked), "no icon here")
    }

    func testTypedPlainTokenSerializesVerbatimOutsideNativeSyntax() {
        let snapshot = BuiltInPluginRegistry.snapshot(for: frontmatter + "\nprose [?]")
        let typed = NSAttributedString(string: "see [X] here, not ![X] or [X](url)")
        let serialized = serializeAttributedToMarkdown(typed, pluginSnapshot: snapshot)

        XCTAssertTrue(serialized.contains("see [X] here"), serialized)
        XCTAssertTrue(serialized.contains(#"!\[X\]"#), serialized)
        XCTAssertTrue(serialized.contains(#"\[X\]\(url)"#) ||
                      serialized.contains(#"\[X\](url)"#), serialized)
        // Without an active plugin the old escaping stands.
        XCTAssertEqual(serializeAttributedToMarkdown(NSAttributedString(string: "[X]")),
                       #"\[X\]"#)
    }

    func testEscapedLiteralMarkerRoundTripsAndStaysInert() throws {
        let markdown = frontmatter + "\nprose \\[X\\] stays literal"
        let snapshot = BuiltInPluginRegistry.snapshot(for: markdown)
        let attributed = renderMarkdownToAttributed(markdown)

        let literalRange = (attributed.string as NSString).range(of: "[X]")
        XCTAssertNotEqual(literalRange.location, NSNotFound, attributed.string)
        let payload = try XCTUnwrap(attributed.attribute(
            .mdBuiltInPluginToken, at: literalRange.location,
            effectiveRange: nil) as? BuiltInPluginTokenPayload)
        XCTAssertFalse(payload.isInteractive)
        XCTAssertEqual(payload.state.source, "\\[X\\]")

        XCTAssertEqual(
            composeDocumentWithFrontmatter(
                frontmatter,
                body: serializeAttributedToMarkdown(attributed, pluginSnapshot: snapshot)),
            frontmatter + "\n\nprose \\[X\\] stays literal")
    }

    func testTableRebuildPipelineIsByteStableForEscapesAndTokens() throws {
        // The full Visual insert-row pipeline: serialize the rendered table →
        // grid mutation → re-render the fragment → serialize. Tokens stay
        // tokens, `\_` escapes stay single — this exact path used to produce
        // `\[X\]` and `vitamin\\\_d`.
        let body = "| S | V |\n| --- | --- |\n| [X] | vitamin\\_d |"
        let markdown = frontmatter + "\n" + body
        let snapshot = BuiltInPluginRegistry.snapshot(for: markdown)
        let serializedTable = serializeAttributedToMarkdown(
            renderMarkdownToAttributed(markdown), pluginSnapshot: snapshot)
        XCTAssertEqual(serializedTable, body)

        var grid = try XCTUnwrap(parseGFMTable(serializedTable))
        grid.insertRow(at: 1)
        let fragment = serializeGFMTable(grid)
        let rerendered = renderMarkdownToAttributed(
            fragment,
            pluginSnapshot: BuiltInPluginRegistry.snapshot(forFragment: fragment,
                                                           in: snapshot))
        XCTAssertEqual(serializeAttributedToMarkdown(rerendered, pluginSnapshot: snapshot),
                       body + "\n|  |  |")
    }

    func testVisualRoundTripNeverSerializesSentinelsForInactiveCoreCheckboxes() {
        let markdown = frontmatter + "\n- [ ] open\n- [x] done"
        let attributed = renderMarkdownToAttributed(markdown)
        let serialized = serializeAttributedToMarkdown(attributed)

        XCTAssertFalse(attributed.string.utf16.contains(builtInPluginSentinelUnit),
                       attributed.string)
        XCTAssertFalse(serialized.utf16.contains(builtInPluginSentinelUnit), serialized)
        XCTAssertTrue(serialized.contains("- [ ] open"), serialized)
        XCTAssertTrue(serialized.contains("- [x] done"), serialized)
    }

    func testTableCellUsesPositionedPluginCandidatesAndSkipsProtectedSyntax() {
        let snapshot = BuiltInPluginRegistry.snapshot(for: frontmatter + "\nprose [?]")
        let cell = "plain [?] `[?]` [[Note|[?]]] $[?]$ [link](url) [?](url)"

        let attributed = renderTableCellAttributed(
            cell, baseFont: .systemFont(ofSize: 14), textColor: .labelColor,
            linkColor: .linkColor, codeColor: .systemOrange,
            pluginSnapshot: snapshot)
        var pluginRuns = 0
        attributed.enumerateAttribute(.mdBuiltInPluginToken,
                                      in: NSRange(location: 0, length: attributed.length)) {
            value, _, _ in
            if value is BuiltInPluginTokenPayload { pluginRuns += 1 }
        }
        XCTAssertEqual(pluginRuns, 1)
    }

    func testTableCellKeepsEscapedPluginMarkerLiteral() {
        let snapshot = BuiltInPluginRegistry.snapshot(for: frontmatter + "\nprose [?]")
        let cell = #"🧬 escaped \[?\] live [?]"#
        let attributed = renderTableCellAttributed(
            cell, baseFont: .systemFont(ofSize: 14), textColor: .labelColor,
            linkColor: .linkColor, codeColor: .systemOrange,
            pluginSnapshot: snapshot)

        let literalRange = (attributed.string as NSString).range(of: "[?]")
        XCTAssertNotEqual(literalRange.location, NSNotFound, attributed.string)
        XCTAssertNil(attributed.attribute(.mdBuiltInPluginToken,
                                          at: literalRange.location,
                                          effectiveRange: nil))
        var pluginRuns = 0
        attributed.enumerateAttribute(.mdBuiltInPluginToken,
                                      in: NSRange(location: 0, length: attributed.length)) {
            value, _, _ in
            if value is BuiltInPluginTokenPayload { pluginRuns += 1 }
        }
        XCTAssertEqual(pluginRuns, 1, attributed.string)
    }

    func testCachedSnapshotCyclesTableCellThroughStatesAbsentAtLoad() throws {
        let markdown = frontmatter + "\n| Status |\n| --- |\n| [-] |"
        let snapshot = BuiltInPluginRegistry.snapshot(for: markdown)
        XCTAssertEqual(snapshot.tokens.filter(\.payload.isInteractive)
            .map { $0.payload.state.source }, ["[-]"])

        var source = "[-]"
        for expected in ["[?]", "[X]", "[-]"] {
            let payload = try XCTUnwrap(snapshot.payload(matchingSource: source))
            source = payload.next.state.source
            XCTAssertEqual(source, expected)

            let rendered = renderTableCellAttributed(
                source, baseFont: .systemFont(ofSize: 14), textColor: .labelColor,
                linkColor: .linkColor, codeColor: .systemOrange,
                pluginSnapshot: snapshot)
            XCTAssertNotNil(rendered.attribute(.mdBuiltInPluginToken, at: 0,
                                               effectiveRange: nil), source)
        }
    }

    func testInlinePluginHitTestingRejectsNearestGlyphOutsideTokenRect() {
        let storage = NSTextStorage(string: "?")
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: 100))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let range = NSRange(location: 0, length: 1)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                  actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)

        XCTAssertTrue(visualPointHitsCharacterRange(
            NSPoint(x: rect.midX, y: rect.midY), range: range,
            layoutManager: layoutManager, textContainer: container))
        XCTAssertFalse(visualPointHitsCharacterRange(
            NSPoint(x: rect.maxX + 30, y: rect.midY), range: range,
            layoutManager: layoutManager, textContainer: container))
        XCTAssertFalse(visualPointHitsCharacterRange(
            NSPoint(x: rect.midX, y: rect.maxY + 30), range: range,
            layoutManager: layoutManager, textContainer: container))
    }

    func testChecklistFormattingUsesPluginFirstStateAndRecognizesPluginTasks() throws {
        let snapshot = BuiltInPluginRegistry.snapshot(for: frontmatter + "\nprose [?]")
        let payload = try XCTUnwrap(snapshot.initialChecklistPayload)
        let kind = checklistKind(depth: 2, initialPluginPayload: payload)

        XCTAssertTrue(isChecklistKind(kind))
        guard case .builtInPluginTaskItem(let depth, let token) = kind else {
            return XCTFail("expected built-in plugin checklist")
        }
        XCTAssertEqual(depth, 2)
        XCTAssertEqual(token.state.source, "[-]")
        XCTAssertTrue(isChecklistKind(.taskItem(depth: 0, done: false)))
        XCTAssertFalse(isChecklistKind(.bulletItem(depth: 0)))
        XCTAssertTrue(allBlocksAreChecklists([MDBlock(kind: kind)]))
        XCTAssertTrue(allBlocksAreChecklists([
            MDBlock(kind: kind), MDBlock(kind: .taskItem(depth: 0, done: false)),
        ]))
        XCTAssertFalse(allBlocksAreChecklists([MDBlock(kind: .bulletItem(depth: 0))]))
    }

    func testPluginSnapshotRefreshesOnlyWhenFrontmatterChanges() {
        let original = frontmatter + "\nprose [?]"
        var cachedFrontmatter = builtInPluginFrontmatterSource(in: original)
        var snapshot = BuiltInPluginRegistry.snapshot(for: original)

        XCTAssertFalse(refreshBuiltInPluginSnapshot(
            for: frontmatter + "\nchanged prose [?]",
            cachedFrontmatter: &cachedFrontmatter, snapshot: &snapshot))
        XCTAssertNotNil(snapshot.payload(matchingSource: "[?]"))

        XCTAssertTrue(refreshBuiltInPluginSnapshot(
            for: "changed prose [?]",
            cachedFrontmatter: &cachedFrontmatter, snapshot: &snapshot))
        XCTAssertNil(cachedFrontmatter)
        XCTAssertTrue(snapshot.activations.isEmpty)
        XCTAssertNil(snapshot.payload(matchingSource: "[?]"))
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
        XCTAssertFalse(html.contains("<input type=\"checkbox\" disabled"), html)
        XCTAssertFalse(html.contains("class=\"multi-checkbox\""), html)
        XCTAssertTrue(html.contains(">[ ]</span>"), html)
        XCTAssertTrue(html.contains(">[x]</span>"), html)
    }
}

struct BuiltInPluginPreviewConfigurationTests {
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

    @Test func checklistCardsExposeStatesInCycleOrderWithoutTokenScan() throws {
        let cards = BuiltInPluginRegistry.checklistCards(in: frontmatter + "\n[-] Item")

        let card = try #require(cards.first)
        #expect(cards.count == 1)
        #expect(card.descriptor.id == "multi-checkbox")
        #expect(card.states.map(\.source) == ["[-]", "[?]", "[X]"])
        #expect(card.states.map(\.label) == ["Queued", "Needs review", "Done"])
        #expect(card.states[1].icon == .emoji("❓"))
        #expect(card.states[2].strikethrough)
        #expect(BuiltInPluginRegistry.checklistCards(in: "# no plugins").isEmpty)
    }

    @Test func previewPageCarriesNoPluginCardMachinery() {
        let html = markdownHTMLBody(frontmatter + "\n[-] Item")
        let page = previewHTMLPage(markdown: frontmatter, fontSize: 14)

        // The plugin settings card moved to the Properties inspector; the page
        // keeps only the interactive checkbox tokens themselves.
        #expect(!html.contains("fm-plugin"))
        #expect(!page.contains("hydrateBuiltInPluginConfiguration"))
        #expect(!page.contains("handlers.builtInPluginConfiguration"))
        #expect(page.contains("hydrateBuiltInPluginTokens"))
    }

    @Test func iconAndStrikeEditsUpdateOnlyTheSelectedState() throws {
        let withComment = frontmatter.replacingOccurrences(
            of: "icon: \"sf:circle\"", with: "icon: \"sf:circle\" # keep me")
        let iconUpdated = try #require(BuiltInPluginRegistry.updateConfiguration(
            in: withComment, pluginID: MultiCheckboxPlugin.pluginID,
            stateIndex: 0, field: .icon, value: "emoji:📥"))
        let strikeUpdated = try #require(BuiltInPluginRegistry.updateConfiguration(
            in: iconUpdated, pluginID: MultiCheckboxPlugin.pluginID,
            stateIndex: 0, field: .strikethrough, value: "true"))
        let configuration = try #require(MultiCheckboxPlugin.configuration(in: strikeUpdated))

        #expect(iconUpdated.contains("icon: \"emoji:📥\" # keep me"))
        #expect(configuration.states[0].icon == .emoji("📥"))
        #expect(configuration.states[0].strikethrough)
        #expect(configuration.states[1].icon == .emoji("❓"))
    }

    @Test func markerEditMigratesExistingTokensButLeavesProtectedText() throws {
        let markdown = frontmatter + "\n- [-] queued\n\nprose [-]\n\n`[-]`"
        let updated = try #require(BuiltInPluginRegistry.updateConfiguration(
            in: markdown, pluginID: MultiCheckboxPlugin.pluginID,
            stateIndex: 0, field: .marker, value: "="))

        #expect(updated.contains("marker: \"=\""))
        #expect(updated.contains("- [=] queued"))
        #expect(updated.contains("prose [=]"))
        #expect(updated.contains("`[-]`"))
        #expect(MultiCheckboxPlugin.configuration(in: updated)?.states[0].source == "[=]")
    }

    @Test func duplicateOrMultiUnitMarkerEditIsRejected() {
        #expect(BuiltInPluginRegistry.updateConfiguration(
            in: frontmatter, pluginID: MultiCheckboxPlugin.pluginID,
            stateIndex: 0, field: .marker, value: "?") == nil)
        #expect(BuiltInPluginRegistry.updateConfiguration(
            in: frontmatter, pluginID: MultiCheckboxPlugin.pluginID,
            stateIndex: 0, field: .marker, value: "😀") == nil)
    }

    @Test func editSupportsIndentlessStateSequence() throws {
        let markdown = """
        ---
        editmd:
          plugins:
            multi-checkbox:
              states:
              - marker: "-"
              - marker: "?"
        ---
        """
        let updated = try #require(BuiltInPluginRegistry.updateConfiguration(
            in: markdown, pluginID: MultiCheckboxPlugin.pluginID,
            stateIndex: 0, field: .icon, value: "emoji:📥"))

        #expect(updated.contains("  icon: \"emoji:📥\""))
        #expect(MultiCheckboxPlugin.configuration(in: updated)?.states[0].icon == .emoji("📥"))
    }

    @Test func staleConfigurationEditIsRejectedByExpectedSource() {
        #expect(BuiltInPluginRegistry.updateConfiguration(
            in: frontmatter, pluginID: MultiCheckboxPlugin.pluginID,
            stateIndex: 1, field: .label, value: "Wrong state",
            expectedSource: "[-]") == nil)
    }

    @Test func installsTemplateWithEmptyBoxFirstWithoutFrontmatter() throws {
        let updated = try #require(BuiltInPluginRegistry.installPlugin(
            id: MultiCheckboxPlugin.pluginID, in: "# Existing title"))
        let configuration = try #require(MultiCheckboxPlugin.configuration(in: updated))

        #expect(configuration.states.map(\.source) == ["[ ]", "[-]"])
        #expect(configuration.states[0].label == "To do")
        #expect(configuration.states[0].icon == .sfSymbol("square"))
        #expect(configuration.states[1].icon == .sfSymbol("circle"))
        #expect(updated.hasSuffix("# Existing title"))
        #expect(BuiltInPluginRegistry.declaredPluginIDs(in: updated)
            == Set([MultiCheckboxPlugin.pluginID]))
        #expect(BuiltInPluginRegistry.installPlugin(
            id: MultiCheckboxPlugin.pluginID, in: updated) == nil)
        let tokenDocument = updated + "\n[-] One item"
        let offset = (tokenDocument as NSString).range(of: "[-]", options: .backwards).location
        let cycled = try #require(BuiltInPluginRegistry.cycleToken(in: tokenDocument,
                                                                   at: offset))
        #expect(cycled.hasSuffix("[ ] One item"))
        let html = markdownHTMLBody(tokenDocument)
        #expect(html.contains("class=\"multi-checkbox\""))
        #expect(!html.contains("disabled aria-disabled=\"true\""))
        let token = try #require(BuiltInPluginRegistry.snapshot(for: tokenDocument)
            .token(startingAt: offset))
        #expect(token.payload.canCycle)
    }

    @Test func duplicateMarkersProduceVisibleConfigurationDiagnostic() throws {
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

        let diagnostic = try #require(
            BuiltInPluginRegistry.configurationDiagnostics(in: duplicates).first)
        #expect(diagnostic.descriptor.id == MultiCheckboxPlugin.pluginID)
        #expect(diagnostic.message == "Duplicate marker: [x].")
        // The page never shows the invalid block; the Properties inspector
        // surfaces this diagnostic natively.
        #expect(!markdownHTMLBody(duplicates).contains("fm-plugin"))
        #expect(BuiltInPluginRegistry.checklistCards(in: duplicates).isEmpty)
    }

    @Test func visualStatusBarSurfacesDeclaredPluginConfigurationIssue() throws {
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

        let visual = builtInPluginConfigurationDiagnosticsForStatusBar(
            mode: .visual, markdown: duplicates)
        let diagnostic = try #require(visual.first)
        #expect(visual.count == 1)
        #expect(diagnostic.descriptor.name == "Multi-checkbox")
        #expect(diagnostic.message == "Duplicate marker: [x].")

        for mode in [EditorMode.source, .preview, .split] {
            #expect(builtInPluginConfigurationDiagnosticsForStatusBar(
                mode: mode, markdown: duplicates).isEmpty)
        }
        #expect(builtInPluginConfigurationDiagnosticsForStatusBar(
            mode: .visual, markdown: frontmatter).isEmpty)
    }

    @Test(arguments: [
        """
        ---
        title: Existing
        ---
        Body
        """,
        """
        ---
        editmd:
          another-setting: true
        ---
        Body
        """,
        """
        ---
        editmd:
          plugins:
            another-plugin:
              enabled: true
        ---
        Body
        """,
    ])
    func installsIntoExistingFrontmatterShapes(_ markdown: String) throws {
        let updated = try #require(BuiltInPluginRegistry.installPlugin(
            id: MultiCheckboxPlugin.pluginID, in: markdown))

        #expect(MultiCheckboxPlugin.configuration(in: updated)?.states.count == 2)
        #expect(updated.contains("title: Existing") || updated.contains("another-setting: true")
                || updated.contains("another-plugin:"))
        #expect(updated.hasSuffix("Body"))
    }

    @Test func addStateAppendsAfterInstalledTemplate() throws {
        let installed = try #require(BuiltInPluginRegistry.installPlugin(
            id: MultiCheckboxPlugin.pluginID, in: "Body"))
        let updated = try #require(BuiltInPluginRegistry.addConfigurationState(
            pluginID: MultiCheckboxPlugin.pluginID, in: installed))
        let configuration = try #require(MultiCheckboxPlugin.configuration(in: updated))

        #expect(configuration.states.map(\.source) == ["[ ]", "[-]", "[x]"])
        #expect(configuration.states[2].label == "State 3")
        #expect(BuiltInPluginRegistry.checklistCards(in: updated)
            .first?.states.count == 3)
    }
}
