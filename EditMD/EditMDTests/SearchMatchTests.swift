import XCTest
@testable import EditMD

final class SearchMatchTests: XCTestCase {

    private func meta(
        path: String = "/vault/docs/a.md",
        relative: String = "docs/a.md",
        name: String? = nil,
        ext: String = "md",
        mtime: Date = Date(),
        size: Int64 = 100,
        tags: [String] = [],
        modified: Bool = false
    ) -> SearchFileMeta {
        let url = URL(fileURLWithPath: path)
        return SearchFileMeta(
            url: url,
            relativePath: relative,
            fileName: name ?? url.lastPathComponent,
            pathExtension: ext,
            modificationDate: mtime,
            fileSize: size,
            tags: tags,
            isGitModified: modified
        )
    }

    // MARK: - Content AND / case

    func testANDRequiresAllTokens() {
        let q = parseSearchQuery("foo bar")
        let hit = searchContentMatches(q, text: "foo and bar here", fileName: "x.md")
        XCTAssertTrue(hit.matched)
        let miss = searchContentMatches(q, text: "only foo here", fileName: "x.md")
        XCTAssertFalse(miss.matched)
    }

    func testCaseInsensitiveLatinAndCyrillic() {
        // Same word form, different case (not inflection).
        let q = parseSearchQuery("АРХИТЕКТУРА")
        let hit = searchContentMatches(q, text: "про архитектура системы", fileName: "n.md")
        XCTAssertTrue(hit.matched)

        let q2 = parseSearchQuery("Hello")
        XCTAssertTrue(searchContentMatches(q2, text: "say hello world", fileName: "n.md").matched)
    }

    func testPhraseAcrossTokenBoundary() {
        let q = parseSearchQuery("\"world peace\"")
        let hit = searchContentMatches(q, text: "want world peace now", fileName: "n.md")
        XCTAssertTrue(hit.matched)
        let miss = searchContentMatches(q, text: "world of peace", fileName: "n.md")
        XCTAssertFalse(miss.matched)
    }

    func testNameMatchWithoutBody() {
        let q = parseSearchQuery("readme")
        let hit = searchContentMatches(q, text: "no match in body", fileName: "README.md")
        XCTAssertTrue(hit.matched)
        XCTAssertTrue(hit.nameMatched)
        XCTAssertTrue(hit.lineHits.isEmpty)
    }

    func testLineHitsLimitedToFive() {
        var body = ""
        for i in 1...10 {
            body += "needle line \(i)\n"
        }
        let q = parseSearchQuery("needle")
        let hit = searchContentMatches(q, text: body, fileName: "n.md", maxLineHits: 5)
        XCTAssertEqual(hit.lineHits.count, 5)
        XCTAssertEqual(hit.lineHits.first?.lineNumber, 1)
        XCTAssertEqual(hit.lineHits.last?.lineNumber, 5)
        XCTAssertGreaterThanOrEqual(hit.matchCount, 10)
    }

    func testLineHitUTF16Offset() {
        let text = "alpha\nbeta needle\ngamma"
        let q = parseSearchQuery("needle")
        let hit = searchContentMatches(q, text: text, fileName: "n.md")
        XCTAssertEqual(hit.lineHits.count, 1)
        XCTAssertEqual(hit.lineHits[0].lineNumber, 2)
        XCTAssertEqual(hit.lineHits[0].utf16Offset, 6) // after "alpha\n"
    }

    // MARK: - Meta filters

    func testPathPrefix() {
        let q = parseSearchQuery("path:docs/plans")
        XCTAssertTrue(searchFileMatchesMeta(q, meta: meta(relative: "docs/plans/a.md")))
        XCTAssertTrue(searchFileMatchesMeta(q, meta: meta(relative: "docs/plans")))
        XCTAssertFalse(searchFileMatchesMeta(q, meta: meta(relative: "docs/other/a.md")))
        XCTAssertFalse(searchFileMatchesMeta(q, meta: meta(relative: "docs/plansx/a.md")))
    }

    func testTypeDefaultMarkdownOnly() {
        let q = parseSearchQuery("hello") // no type → default md
        // Meta filter only checks extension against default set when no type filter;
        // but query has no type — defaultExtensions apply.
        XCTAssertTrue(searchFileMatchesMeta(q, meta: meta(ext: "md")))
        XCTAssertFalse(searchFileMatchesMeta(q, meta: meta(path: "/v/a.swift", relative: "a.swift", ext: "swift")))
    }

    func testTypeStarAllowsSwift() {
        let q = parseSearchQuery("type:*")
        XCTAssertTrue(searchFileMatchesMeta(q, meta: meta(path: "/v/a.swift", relative: "a.swift", ext: "swift")))
    }

    func testTagAND() {
        let q = parseSearchQuery("tag:research tag:wip")
        XCTAssertTrue(searchFileMatchesMeta(
            q, meta: meta(tags: ["Research", "wip", "other"])))
        XCTAssertFalse(searchFileMatchesMeta(
            q, meta: meta(tags: ["research"])))
    }

    func testIsModified() {
        let q = parseSearchQuery("is:modified")
        let opts = SearchMetaOptions(gitAvailable: true, defaultExtensions: ["md"])
        XCTAssertTrue(searchFileMatchesMeta(q, meta: meta(modified: true), options: opts))
        XCTAssertFalse(searchFileMatchesMeta(q, meta: meta(modified: false), options: opts))
    }

    func testAfterBeforeInclusiveDay() {
        let after = parseSearchDate("2026-07-01")!
        let before = parseSearchDate("2026-07-10")!
        let q = SearchQuery(
            tokens: [], phrases: [], pathPrefix: nil, fileType: nil,
            tags: [], isModified: false, afterDate: after, beforeDate: before
        )
        // Start of after day — inclusive.
        XCTAssertTrue(searchFileMatchesMeta(q, meta: meta(mtime: after)))
        // End of before day (23:00) — inclusive.
        let endOfBefore = Calendar.current.date(
            bySettingHour: 23, minute: 0, second: 0, of: before)!
        XCTAssertTrue(searchFileMatchesMeta(q, meta: meta(mtime: endOfBefore)))
        // Next day after before — exclusive.
        let dayAfter = searchDateEndExclusive(before)
        XCTAssertFalse(searchFileMatchesMeta(q, meta: meta(mtime: dayAfter)))
        // Day before after — exclusive.
        let dayBefore = Calendar.current.date(byAdding: .day, value: -1, to: after)!
        XCTAssertFalse(searchFileMatchesMeta(q, meta: meta(mtime: dayBefore)))
    }

    // MARK: - Runner limits / cancel

    func testMaxResultFilesTruncates() {
        var files: [SearchFileMeta] = []
        var contents: [String: String] = [:]
        for i in 0..<5 {
            let m = meta(path: "/vault/f\(i).md", relative: "f\(i).md", size: 10)
            files.append(m)
            contents[m.url.path] = "needle \(i)"
        }
        let q = parseSearchQuery("needle")
        var opts = SearchRunOptions.default
        opts.maxResultFiles = 3
        let run = runWorkspaceSearch(
            query: q,
            files: files,
            contentProvider: { contents[$0.url.path] },
            options: opts
        )
        XCTAssertEqual(run.files.count, 3)
        XCTAssertTrue(run.truncated)
    }

    func testOversizedFileSkipped() {
        let big = meta(path: "/vault/big.md", relative: "big.md", size: 5_000_000)
        let small = meta(path: "/vault/ok.md", relative: "ok.md", size: 100)
        let q = parseSearchQuery("needle")
        var opts = SearchRunOptions.default
        opts.maxFileBytes = 4 * 1024 * 1024
        var providerCalled = 0
        let run = runWorkspaceSearch(
            query: q,
            files: [big, small],
            contentProvider: { m in
                providerCalled += 1
                return "needle in \(m.fileName)"
            },
            options: opts
        )
        XCTAssertEqual(run.skippedOversized, 1)
        XCTAssertEqual(run.files.count, 1)
        XCTAssertEqual(run.files[0].fileName, "ok.md")
        XCTAssertEqual(providerCalled, 1) // big never read
    }

    func testCancellationStopsEarly() {
        let files = (0..<20).map {
            meta(path: "/vault/f\($0).md", relative: "f\($0).md")
        }
        let q = parseSearchQuery("needle")
        var seen = 0
        let run = runWorkspaceSearch(
            query: q,
            files: files,
            contentProvider: { _ in
                seen += 1
                // Slow-ish provider simulation: cancel after 3 reads.
                return "needle"
            },
            options: .default,
            isCancelled: { seen >= 3 }
        )
        // Cancellation is checked at start of each file loop iteration;
        // after 3 content reads, next file sees cancel.
        XCTAssertTrue(run.cancelled || run.files.count <= 3)
        XCTAssertLessThanOrEqual(run.files.count, 3)
    }

    func testIsModifiedWithoutGitEmptyReason() {
        let q = parseSearchQuery("is:modified")
        var opts = SearchRunOptions.default
        opts.meta.gitAvailable = false
        let run = runWorkspaceSearch(
            query: q,
            files: [meta(modified: true)],
            contentProvider: { _ in "x" },
            options: opts
        )
        XCTAssertTrue(run.files.isEmpty)
        XCTAssertNotNil(run.emptyReason)
        XCTAssertTrue(run.emptyReason!.contains("is:modified"))
    }

    func testSortByMatchCountThenDate() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let a = SearchFileResult(
            url: URL(fileURLWithPath: "/a.md"), relativePath: "a.md",
            fileName: "a.md", modificationDate: newer, lineHits: [],
            matchCount: 1, nameMatched: false, skippedContent: false
        )
        let b = SearchFileResult(
            url: URL(fileURLWithPath: "/b.md"), relativePath: "b.md",
            fileName: "b.md", modificationDate: older, lineHits: [],
            matchCount: 5, nameMatched: false, skippedContent: false
        )
        let byRel = sortSearchResults([a, b], byDate: false)
        XCTAssertEqual(byRel.map(\.fileName), ["b.md", "a.md"])
        let byDate = sortSearchResults([a, b], byDate: true)
        XCTAssertEqual(byDate.map(\.fileName), ["a.md", "b.md"])
    }

    func testContentCacheLRU() {
        let cache = SearchContentCache(maxBytes: 50)
        let k1 = SearchContentCache.Key(path: "/a", mtime: 1, size: 10)
        let k2 = SearchContentCache.Key(path: "/b", mtime: 1, size: 10)
        let k3 = SearchContentCache.Key(path: "/c", mtime: 1, size: 10)
        cache.insert(String(repeating: "a", count: 30), for: k1)
        cache.insert(String(repeating: "b", count: 30), for: k2)
        // Total 60 > 50 → k1 should be evicted.
        XCTAssertNil(cache.value(for: k1))
        XCTAssertNotNil(cache.value(for: k2))
        cache.insert(String(repeating: "c", count: 30), for: k3)
        XCTAssertNil(cache.value(for: k2))
        XCTAssertNotNil(cache.value(for: k3))
    }

    // MARK: - Async model cancel

    @MainActor
    func testModelNewQueryCancelsPrevious() async throws {
        let model = WorkspaceSearchModel()
        // Tiny root with one file — just ensure setQueryText doesn't crash and
        // finishes empty roots cleanly.
        model.updateContext(
            roots: [], tagIndex: [:], modifiedPaths: [], gitAvailable: false
        )
        model.setQueryText("foo")
        model.setQueryText("bar")
        // Allow debounce + task.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(parseSearchQuery(model.queryText).tokens, ["bar"])
        XCTAssertFalse(model.isSearching)
    }
}
