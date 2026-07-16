import XCTest
@testable import EditMD

final class SearchQueryTests: XCTestCase {

    // MARK: - Empty / free text

    func testEmptyQuery() {
        let q = parseSearchQuery("")
        XCTAssertTrue(q.isEmpty)
        XCTAssertTrue(q.tokens.isEmpty)
        XCTAssertTrue(q.phrases.isEmpty)

        let ws = parseSearchQuery("   \t  ")
        XCTAssertTrue(ws.isEmpty)
    }

    func testANDTokens() {
        let q = parseSearchQuery("архитектура запрос")
        XCTAssertEqual(q.tokens, ["архитектура", "запрос"])
        XCTAssertTrue(q.phrases.isEmpty)
        XCTAssertFalse(q.isEmpty)
    }

    func testQuotedPhrase() {
        let q = parseSearchQuery("\"точная фраза\"")
        XCTAssertEqual(q.phrases, ["точная фраза"])
        XCTAssertTrue(q.tokens.isEmpty)
    }

    func testPhraseAndTokens() {
        let q = parseSearchQuery("hello \"world peace\" foo")
        XCTAssertEqual(q.tokens, ["hello", "foo"])
        XCTAssertEqual(q.phrases, ["world peace"])
    }

    func testUnclosedQuoteTakesRemainder() {
        let q = parseSearchQuery("before \"open phrase rest")
        XCTAssertEqual(q.tokens, ["before"])
        XCTAssertEqual(q.phrases, ["open phrase rest"])
    }

    func testEmptyQuotesIgnored() {
        let q = parseSearchQuery("a \"\" b")
        XCTAssertEqual(q.tokens, ["a", "b"])
        XCTAssertTrue(q.phrases.isEmpty)
    }

    // MARK: - Filters

    func testPathFilter() {
        let q = parseSearchQuery("path:docs/plans")
        XCTAssertEqual(q.pathPrefix, "docs/plans")
        XCTAssertTrue(q.tokens.isEmpty)
    }

    func testPathWithLeadingSlashStripped() {
        let q = parseSearchQuery("path:/docs")
        XCTAssertEqual(q.pathPrefix, "docs")
    }

    func testPathQuotedWithSpacesAndCyrillic() {
        let q = parseSearchQuery("path:\"мои заметки\"")
        XCTAssertEqual(q.pathPrefix, "мои заметки")
        XCTAssertTrue(q.tokens.isEmpty)
        XCTAssertTrue(q.phrases.isEmpty)
    }

    func testTypeMdAndStar() {
        let md = parseSearchQuery("type:md")
        XCTAssertEqual(md.fileType, .fileExtension("md"))

        let dot = parseSearchQuery("type:.markdown")
        XCTAssertEqual(dot.fileType, .fileExtension("markdown"))

        let all = parseSearchQuery("type:*")
        XCTAssertEqual(all.fileType, .allText)
    }

    func testTagFilter() {
        let q = parseSearchQuery("tag:research")
        XCTAssertEqual(q.tags, ["research"])
    }

    func testMultipleTagsAND() {
        let q = parseSearchQuery("tag:a tag:b")
        XCTAssertEqual(q.tags, ["a", "b"])
    }

    func testIsModified() {
        let q = parseSearchQuery("is:modified")
        XCTAssertTrue(q.isModified)
        XCTAssertTrue(q.tokens.isEmpty)
    }

    func testUnknownIsValueBecomesToken() {
        let q = parseSearchQuery("is:draft")
        XCTAssertFalse(q.isModified)
        XCTAssertEqual(q.tokens, ["is:draft"])
    }

    func testAfterBeforeDates() {
        let q = parseSearchQuery("after:2026-07-01 before:2026-07-15")
        XCTAssertNotNil(q.afterDate)
        XCTAssertNotNil(q.beforeDate)

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: q.afterDate!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 1)

        comps = Calendar.current.dateComponents([.year, .month, .day], from: q.beforeDate!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 15)
    }

    func testInvalidDateBecomesToken() {
        let q = parseSearchQuery("after:not-a-date")
        XCTAssertNil(q.afterDate)
        XCTAssertEqual(q.tokens, ["after:not-a-date"])
    }

    func testMultipleFiltersCombined() {
        let q = parseSearchQuery(
            "архитектура path:docs type:md tag:research is:modified after:2026-01-01"
        )
        XCTAssertEqual(q.tokens, ["архитектура"])
        XCTAssertEqual(q.pathPrefix, "docs")
        XCTAssertEqual(q.fileType, .fileExtension("md"))
        XCTAssertEqual(q.tags, ["research"])
        XCTAssertTrue(q.isModified)
        XCTAssertNotNil(q.afterDate)
    }

    // MARK: - Soft degrade

    func testUnknownKeyBecomesToken() {
        let q = parseSearchQuery("foo:bar hello")
        XCTAssertEqual(q.tokens, ["foo:bar", "hello"])
        XCTAssertNil(q.pathPrefix)
    }

    func testColonWithoutKeyLikeShape() {
        // Starts with digit / empty key — not a filter.
        let q = parseSearchQuery("12:34")
        XCTAssertEqual(q.tokens, ["12:34"])
    }

    // MARK: - Date helpers (boundary contract)

    func testParseSearchDateStartOfDay() {
        guard let d = parseSearchDate("2026-07-01") else {
            return XCTFail("parse failed")
        }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)
    }

    func testBeforeEndExclusiveIsNextDay() {
        guard let d = parseSearchDate("2026-07-01") else {
            return XCTFail("parse failed")
        }
        let end = searchDateEndExclusive(d)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: end)
        XCTAssertEqual(comps.day, 2)
        XCTAssertEqual(comps.month, 7)
    }

    // MARK: - Tokenizer edge cases

    func testTokenizeQuotedPathLikeWord() {
        let pieces = tokenizeSearchQuery(#"path:"a b" token"#)
        // Synthetic word for the filter, then free token.
        XCTAssertEqual(pieces.count, 2)
        if case .word(let w) = pieces[0] {
            XCTAssertEqual(w, "path:a b")
        } else {
            XCTFail("expected word")
        }
        if case .word(let w) = pieces[1] {
            XCTAssertEqual(w, "token")
        } else {
            XCTFail("expected word")
        }
    }
}
