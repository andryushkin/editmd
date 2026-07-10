import XCTest
@testable import EditMD

/// Phase 2 (v37) — smotr-compatible review sidecar: schema fidelity, anchors,
/// rev-guard, suggest application.
final class ReviewMarksTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ReviewClock.now = { Date(timeIntervalSince1970: 1_700_000_000) }  // deterministic
    }

    override func tearDown() {
        ReviewClock.now = { Date() }
        super.tearDown()
    }

    // MARK: Fidelity — real smotr fixtures round-trip without loss

    /// A real smotr html mark (from stepgap): fields EditMD doesn't model
    /// (`vtype`, `page`, `selector`) must survive decode → encode → decode.
    func testHtmlMarkFidelity() throws {
        let json = """
        {
          "rev": 7,
          "marks": [
            {
              "id": "v1783456135040wthy",
              "type": "element",
              "note": "количество не нужно",
              "status": "resolved",
              "ts": 1783456135040,
              "mts": 1783456749941,
              "vtype": "element",
              "page": "?",
              "selector": "body > div:nth-of-type(2) > span",
              "quote": "4",
              "thread": [
                {"role": "claude", "text": "Убрал счётчики.", "ts": 1783456749941}
              ]
            }
          ]
        }
        """
        let doc = try ReviewSidecar.decode(Data(json.utf8))
        let reDoc = try ReviewSidecar.decode(try ReviewSidecar.encode(doc))
        XCTAssertEqual(doc, reDoc, "decode→encode→decode must be a fixed point")

        let m = reDoc.marks[0]
        XCTAssertEqual(m.id, "v1783456135040wthy")
        XCTAssertEqual(m.note, "количество не нужно")
        XCTAssertEqual(m.status, "resolved")
        // Unknown html fields preserved verbatim in `extra`.
        XCTAssertEqual(m.extra["vtype"], .string("element"))
        XCTAssertEqual(m.extra["page"], .string("?"))
        XCTAssertEqual(m.extra["selector"], .string("body > div:nth-of-type(2) > span"))
        XCTAssertEqual(m.thread?.first?.role, "claude")
        XCTAssertEqual(reDoc.rev, 7)
    }

    /// Absent optional fields are neither dropped nor invented on re-encode.
    func testNoFieldInvention() throws {
        let json = #"{"rev":1,"marks":[{"id":"m1","type":"comment","note":"n"}]}"#
        let doc = try ReviewSidecar.decode(Data(json.utf8))
        let out = String(data: try ReviewSidecar.encode(doc), encoding: .utf8)!
        XCTAssertFalse(out.contains("\"prefix\""), "prefix must not be invented")
        XCTAssertFalse(out.contains("\"start\""), "start must not be invented")
        XCTAssertFalse(out.contains("\"status\""), "status must not be invented")
        XCTAssertTrue(out.contains("\"note\" : \"n\""))
    }

    func testPromptsPreserved() throws {
        let json = #"{"rev":2,"marks":[],"prompts":{"intro":{"reply":"hi","ts":123}}}"#
        let doc = try ReviewSidecar.decode(Data(json.utf8))
        XCTAssertEqual(doc.prompts["intro"]?["reply"], .string("hi"))
        let reDoc = try ReviewSidecar.decode(try ReviewSidecar.encode(doc))
        XCTAssertEqual(reDoc.prompts["intro"]?["reply"], .string("hi"))
    }

    // MARK: Status semantics

    func testAbsentStatusIsOpen() throws {
        let json = #"{"marks":[{"id":"m1","type":"fix","quote":"x"}]}"#
        let doc = try ReviewSidecar.decode(Data(json.utf8))
        let m = doc.marks[0]
        XCTAssertTrue(m.isOpen)
        XCTAssertEqual(m.statusOrOpen, "open")
        XCTAssertEqual(doc.openCount, 1)
    }

    func testWorklistPriority() {
        var doc = ReviewDocument()
        doc.marks = [
            mark("a", .cut), mark("b", .question), mark("c", .comment),
            mark("d", .fix), mark("e", .rewrite),
        ]
        XCTAssertEqual(doc.worklist.map(\.id), ["b", "d", "e", "a", "c"])
    }

    // MARK: Anchors — port of smotr `_find_anchor`

    func testAnchorPrefixQuote() {
        let text = "alpha beta gamma beta delta"
        // "beta" appears twice; prefix disambiguates to the second one.
        let r = ReviewSidecar.anchorRange(quote: "beta", prefix: "gamma ", start: 0, in: text)
        XCTAssertNotNil(r)
        XCTAssertEqual(text.distance(from: text.startIndex, to: r!.lowerBound), 17)
    }

    func testAnchorNearStart() {
        let text = "one two three two one"
        // No prefix; start hint points at the second "two" (offset 14).
        let r = ReviewSidecar.anchorRange(quote: "two", prefix: "", start: 60, in: text)
        XCTAssertNotNil(r)
        // hint = max(0, 60-40) = 20 > count(21)? count is 21, 20<21 → search from 20,
        // "two" not found after 20 → global fallback finds first at 4.
        XCTAssertEqual(text.distance(from: text.startIndex, to: r!.lowerBound), 4)
    }

    func testAnchorGlobalFallback() {
        let text = "hello wonderful world"
        let r = ReviewSidecar.anchorRange(quote: "world", prefix: "absent-prefix", start: 0, in: text)
        XCTAssertNotNil(r)
        XCTAssertEqual(String(text[r!]), "world")
    }

    func testAnchorMissing() {
        XCTAssertNil(ReviewSidecar.anchorRange(quote: "ghost", prefix: "", start: 0, in: "no match here"))
        XCTAssertNil(ReviewSidecar.anchorRange(quote: "", prefix: "x", start: 0, in: "text"))
    }

    func testAnchorNSRangeUnicode() {
        let text = "café résumé naïve"
        let m = ReviewMark(type: .comment, quote: "résumé", prefix: "", start: 0, note: "")
        let ns = ReviewSidecar.anchorNSRange(for: m, in: text)
        XCTAssertNotNil(ns)
        XCTAssertEqual((text as NSString).substring(with: ns!), "résumé")
    }

    // MARK: Anchor capture from a selection

    func testCaptureAnchor() {
        let text = "The quick brown fox jumps"
        let lo = text.index(text.startIndex, offsetBy: 10)   // "brown"
        let hi = text.index(text.startIndex, offsetBy: 15)
        let a = ReviewSidecar.captureAnchor(in: text, range: lo..<hi)
        XCTAssertEqual(a.quote, "brown")
        XCTAssertEqual(a.start, 10)
        XCTAssertEqual(a.prefix, "The quick ")   // ≤30 chars before
    }

    func testCaptureAnchorClampsPrefixAtStart() {
        let text = "abc def"
        let lo = text.index(text.startIndex, offsetBy: 0)
        let hi = text.index(text.startIndex, offsetBy: 3)
        let a = ReviewSidecar.captureAnchor(in: text, range: lo..<hi)
        XCTAssertEqual(a.quote, "abc")
        XCTAssertEqual(a.prefix, "")   // nothing before offset 0
    }

    // MARK: Suggest application

    func testApplySuggest() {
        var m = ReviewMark(type: .suggest, quote: "old text", prefix: "the ", start: 4, note: "")
        m.replacement = "new text"
        let out = ReviewSidecar.applySuggest(m, to: "the old text here")
        XCTAssertEqual(out, "the new text here")
    }

    func testApplySuggestRebase() {
        var m = ReviewMark(type: .suggest, quote: "gone", prefix: "", start: 0, note: "")
        m.replacement = "x"
        XCTAssertNil(ReviewSidecar.applySuggest(m, to: "nothing to see"))
    }

    func testApplySuggestRejectsNonSuggest() {
        var m = ReviewMark(type: .fix, quote: "old", prefix: "", start: 0, note: "")
        m.replacement = "new"
        XCTAssertNil(ReviewSidecar.applySuggest(m, to: "old"))
    }

    // MARK: Id + factory

    func testNewMarkIDFormat() {
        let id = ReviewSidecar.newMarkID(at: 1_700_000_000_000)
        XCTAssertTrue(id.hasPrefix("m1700000000000"))
        XCTAssertEqual(id.count, "m1700000000000".count + 4)
    }

    func testMarkFactory() {
        let m = ReviewMark(type: .fix, quote: "q", prefix: "p", start: 5, note: "note")
        XCTAssertEqual(m.type, "fix")
        XCTAssertEqual(m.quote, "q")
        XCTAssertEqual(m.status, "open")
        XCTAssertEqual(m.ts, 1_700_000_000 * 1000)
        XCTAssertEqual(m.thread, [])
    }

    func testEmptyNoteIsNil() {
        let m = ReviewMark(type: .comment, quote: "q", prefix: "", start: 0, note: "")
        XCTAssertNil(m.note)
    }

    func testAppendReply() {
        var m = ReviewMark(type: .question, quote: "q", prefix: "", start: 0, note: "?")
        m.appendReply(role: "claude", text: "answer", at: 999)
        XCTAssertEqual(m.thread?.count, 1)
        XCTAssertEqual(m.thread?.first?.text, "answer")
        XCTAssertEqual(m.mts, 999)
    }

    // MARK: Sidecar path + IO + rev-guard

    func testSidecarPath() {
        let url = URL(fileURLWithPath: "/tmp/notes/plan.md")
        XCTAssertEqual(ReviewSidecar.url(for: url).lastPathComponent, "plan.md.review.json")
    }

    func testSaveFreshBumpsRev() throws {
        let file = tempFile()
        defer { cleanup(file) }
        var doc = ReviewDocument()
        doc.marks = [mark("m1", .fix)]
        let written = try ReviewSidecar.save(doc, for: file, baseRev: 0)
        XCTAssertEqual(written.rev, 1)

        let reloaded = try XCTUnwrap(ReviewSidecar.load(for: file))
        XCTAssertEqual(reloaded.rev, 1)
        XCTAssertEqual(reloaded.marks.map(\.id), ["m1"])
    }

    func testSaveNonStaleIncrements() throws {
        let file = tempFile()
        defer { cleanup(file) }
        // Disk at rev 1, base matches → straightforward increment.
        _ = try ReviewSidecar.save(ReviewDocument(rev: 0, marks: [mark("m1", .fix)]),
                                   for: file, baseRev: 0)
        var doc = try XCTUnwrap(ReviewSidecar.load(for: file))
        doc.upsert(mark("m2", .comment))
        let written = try ReviewSidecar.save(doc, for: file, baseRev: doc.rev)
        XCTAssertEqual(written.rev, 2)
        XCTAssertEqual(Set(written.marks.map(\.id)), ["m1", "m2"])
    }

    /// Concurrent writer advanced the disk rev since we loaded: our save must
    /// merge by id (keep the other writer's mark) instead of clobbering it.
    func testSaveStaleMergesByID() throws {
        let file = tempFile()
        defer { cleanup(file) }
        // Disk now has rev 5 with a mark "other" we never saw.
        _ = try ReviewSidecar.save(
            ReviewDocument(rev: 4, marks: [mark("other", .question)]),
            for: file, baseRev: 4)  // writes rev 5

        // We loaded earlier at rev 3 and are adding "mine".
        let stale = ReviewDocument(rev: 3, marks: [mark("mine", .fix)])
        let written = try ReviewSidecar.save(stale, for: file, baseRev: 3)

        XCTAssertEqual(written.rev, 6, "diskRev(5) + 1")
        XCTAssertEqual(Set(written.marks.map(\.id)), ["other", "mine"],
                       "other writer's mark survives the merge")
    }

    func testDeleteSidecar() throws {
        let file = tempFile()
        defer { cleanup(file) }
        _ = try ReviewSidecar.save(ReviewDocument(marks: [mark("m1", .fix)]), for: file, baseRev: 0)
        XCTAssertNotNil(try ReviewSidecar.load(for: file))
        try ReviewSidecar.delete(for: file)
        XCTAssertNil(try ReviewSidecar.load(for: file))
    }

    // MARK: Helpers

    private func mark(_ id: String, _ type: ReviewMarkType) -> ReviewMark {
        var m = ReviewMark(type: type, quote: "q", prefix: "", start: 0, note: "")
        m.id = id
        return m
    }

    private func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-review-\(UUID().uuidString).md")
    }

    private func cleanup(_ file: URL) {
        try? ReviewSidecar.delete(for: file)
        try? FileManager.default.removeItem(at: file)
    }
}
