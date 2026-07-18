import XCTest
@testable import EditMD

final class WikiCompletionTests: XCTestCase {

    // MARK: - Session detection

    func testTriggersAfterOpenBrackets() {
        let text = "see [[No"
        let caret = (text as NSString).length
        let s = wikiCompletionSession(text: text, caretUTF16: caret)
        XCTAssertEqual(s?.mode, .file)
        XCTAssertEqual(s?.query, "No")
        XCTAssertEqual(s?.replaceRange.length, 2)
    }

    func testNoTriggerSingleBracket() {
        let text = "see [No"
        XCTAssertNil(wikiCompletionSession(text: text, caretUTF16: (text as NSString).length))
    }

    func testNoTriggerWhenClosed() {
        let text = "see [[Note]] more"
        // Caret after closed link.
        let caret = (text as NSString).length
        XCTAssertNil(wikiCompletionSession(text: text, caretUTF16: caret))
    }

    func testNoTriggerInsideFence() {
        let text = "```\n[[No\n```"
        // Caret after [[No
        let caret = ("```\n[[No" as NSString).length
        XCTAssertNil(wikiCompletionSession(text: text, caretUTF16: caret))
    }

    func testNoTriggerInsideInlineCode() {
        let text = "x `[[No` y"
        let caret = ("x `[[No" as NSString).length
        XCTAssertNil(wikiCompletionSession(text: text, caretUTF16: caret))
    }

    func testLeadingSpaceAborts() {
        let text = "[[ Note"
        XCTAssertNil(wikiCompletionSession(text: text, caretUTF16: (text as NSString).length))
    }

    func testHeadingMode() {
        let text = "[[Note#Sec"
        let s = wikiCompletionSession(text: text, caretUTF16: (text as NSString).length)
        guard case .heading(let fileQ) = s?.mode else {
            return XCTFail("expected heading mode")
        }
        XCTAssertEqual(fileQ, "Note")
        XCTAssertEqual(s?.query, "Sec")
    }

    func testUTF16EmojiInQuery() {
        let text = "[[Заметка 📝"
        let s = wikiCompletionSession(text: text, caretUTF16: (text as NSString).length)
        XCTAssertEqual(s?.query, "Заметка 📝")
        XCTAssertEqual(s?.replaceRange.length, ("Заметка 📝" as NSString).length)
    }

    func testPipeAborts() {
        let text = "[[Note|al"
        XCTAssertNil(wikiCompletionSession(text: text, caretUTF16: (text as NSString).length))
    }

    // MARK: - Ranking

    private func cand(_ name: String, title: String? = nil, aliases: [String] = [],
                      path: String? = nil) -> WikiFileCandidate {
        WikiFileCandidate(
            url: URL(fileURLWithPath: "/vault/\(path ?? name + ".md")"),
            basename: name,
            title: title,
            aliases: aliases,
            relativePath: path ?? "\(name).md"
        )
    }

    func testRankPrefixBasenameFirst() {
        let catalog = [
            cand("NoteBook", title: "Other"),
            cand("Other", title: "Note something"),
            cand("Note"),
        ]
        let ranked = rankWikiFileCandidates(query: "Note", catalog: catalog)
        XCTAssertEqual(ranked.first?.basename, "Note")
    }

    func testRankTitleAndAlias() {
        let catalog = [
            cand("a", title: "Magnesium"),
            cand("b", aliases: ["Zinc"]),
            cand("c"),
        ]
        XCTAssertEqual(rankWikiFileCandidates(query: "Mag", catalog: catalog).first?.basename, "a")
        XCTAssertEqual(rankWikiFileCandidates(query: "Zin", catalog: catalog).first?.basename, "b")
    }

    func testRankLimit() {
        let catalog = (0..<50).map { cand("N\($0)") }
        XCTAssertEqual(rankWikiFileCandidates(query: "N", catalog: catalog, limit: 20).count, 20)
    }

    func testPrebuiltRankCatalogMatchesArrayRanking() {
        let catalog = [
            cand("Zulu", aliases: ["Note"]),
            cand("NoteBook"),
            cand("Note"),
            cand("Alpha", title: "Notebook"),
        ]
        let built = WikiRankCatalog(catalog)
        XCTAssertEqual(
            rankWikiFileCandidates(query: "Note", catalog: built, limit: 3)
                .map(\.basename),
            ["Note", "Zulu", "NoteBook"]
        )
        XCTAssertEqual(
            rankWikiFileCandidates(query: "", catalog: built, limit: 2)
                .map(\.basename),
            ["Alpha", "Note"]
        )
    }

    func testRankZeroLimitIsEmpty() {
        XCTAssertTrue(rankWikiFileCandidates(
            query: "N", catalog: WikiRankCatalog([cand("Note")]), limit: 0
        ).isEmpty)
    }

    func testHeadingRank() {
        let heads = ["Introduction", "Intro notes", "Appendix"]
        XCTAssertEqual(rankWikiHeadingCandidates(query: "Intro", headings: heads).first,
                       "Introduction")
        XCTAssertEqual(rankWikiHeadingCandidates(query: "", headings: heads).count, 3)
    }

    // MARK: - Heading normalize / find

    func testNormalizeHeading() {
        XCTAssertEqual(normalizeHeadingKey("  Hello   World  "), "hello world")
        XCTAssertEqual(normalizeHeadingKey("**Bold**"), "bold")
        XCTAssertEqual(normalizeHeadingKey("Hello"), normalizeHeadingKey("hello"))
    }

    func testFindHeadingOffset() {
        let md = "# Intro\n\n## Details\n\ntext\n"
        let off = findHeadingOffset(matching: "details", in: md)
        XCTAssertNotNil(off)
        let items = markdownOutline(md)
        XCTAssertEqual(off, items.first(where: { $0.title == "Details" })?.markdownOffset)
    }

    func testFindHeadingFirstDuplicate() {
        let md = "# A\n\n# A\n"
        let items = markdownOutline(md)
        XCTAssertEqual(findHeadingOffset(matching: "A", in: md), items[0].markdownOffset)
    }

    func testFindHeadingMissing() {
        XCTAssertNil(findHeadingOffset(matching: "Nope", in: "# Yes\n"))
    }

    // MARK: - utf8Contains (ICU-free ranking substring test)

    func testUTF8ContainsBasics() {
        XCTAssertTrue(utf8Contains("hello world", bytes: Array("lo wo".utf8)))
        XCTAssertTrue(utf8Contains("hello", bytes: Array("hello".utf8)))
        XCTAssertTrue(utf8Contains("hello", bytes: []))
        XCTAssertFalse(utf8Contains("hello", bytes: Array("world".utf8)))
        XCTAssertFalse(utf8Contains("he", bytes: Array("hello".utf8)))
        XCTAssertFalse(utf8Contains("", bytes: Array("x".utf8)))
    }

    func testUTF8ContainsCyrillicAndEmoji() {
        XCTAssertTrue(utf8Contains("заметка про кофе", bytes: Array("про".utf8)))
        XCTAssertFalse(utf8Contains("заметка", bytes: Array("кофе".utf8)))
        XCTAssertTrue(utf8Contains("note 📝 file", bytes: Array("📝".utf8)))
    }

    func testUTF8ContainsMatchesLoweredRanking() {
        // Ranking compares pre-lowercased strings; parity with the old
        // `String.contains` path on the lowered forms.
        let hay = "справочник ПО Ошибкам".lowercased()
        let needle = "по ошибкам".lowercased()
        XCTAssertTrue(utf8Contains(hay, bytes: Array(needle.utf8)))
    }
}
