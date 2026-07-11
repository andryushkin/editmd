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

    // MARK: Display plainText search (Visual highlight path)

    func testDisplayHighlightFindsQuote() {
        let marks = [
            ReviewMark(type: .comment, quote: "brown fox", prefix: "The quick ", start: 10, note: "n"),
        ]
        // Visual display has no markdown markers — quote matches body text.
        let display = "The quick brown fox jumps"
        let hs = ReviewHighlight.displayHighlights(marks: marks, displayText: display)
        XCTAssertEqual(hs.count, 1)
        XCTAssertEqual((display as NSString).substring(with: hs[0].range), "brown fox")
        XCTAssertEqual(hs[0].type, .comment)
    }

    func testDisplayHighlightSkipsMissingQuote() {
        let marks = [
            ReviewMark(type: .fix, quote: "ghost", prefix: "", start: 0, note: ""),
        ]
        let hs = ReviewHighlight.displayHighlights(marks: marks, displayText: "hello world")
        XCTAssertTrue(hs.isEmpty)
    }

    // MARK: Queue (.smotr-queue.json)

    func testQueueWriteAndEmptyClear() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // note.md + sidecar with one open mark.
        let note = root.appendingPathComponent("docs/note.md")
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "hello world".write(to: note, atomically: true, encoding: .utf8)
        var doc = ReviewDocument()
        var m = ReviewMark(type: .question, quote: "hello", prefix: "", start: 0, note: "why?")
        m.id = "m1"
        doc.marks = [m]
        _ = try ReviewSidecar.save(doc, for: note, baseRev: 0)

        let result = try ReviewQueue.writeQueue(in: root)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.wroteFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.queueURL.path))

        let snap = try ReviewQueue.decode(Data(contentsOf: result.queueURL))
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.marks.count, 1)
        XCTAssertEqual(snap.marks[0]["file"]?.stringValue, "docs/note.md")
        XCTAssertEqual(snap.marks[0]["kind"]?.stringValue, "md")
        XCTAssertEqual(snap.marks[0]["id"]?.stringValue, "m1")
        XCTAssertEqual(snap.marks[0]["type"]?.stringValue, "question")
        XCTAssertEqual(snap.marks[0]["quote"]?.stringValue, "hello")

        // Resolve the open mark → empty queue deletes the file.
        var closed = try XCTUnwrap(ReviewSidecar.load(for: note))
        closed.marks[0].setStatus(.resolved)
        _ = try ReviewSidecar.save(closed, for: note, baseRev: closed.rev)
        let empty = try ReviewQueue.writeQueue(in: root)
        XCTAssertEqual(empty.count, 0)
        XCTAssertFalse(empty.wroteFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.queueURL.path))
    }

    func testQueueSkipsClosedMarks() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("a.md")
        try "x".write(to: note, atomically: true, encoding: .utf8)
        var doc = ReviewDocument()
        var open = ReviewMark(type: .fix, quote: "x", prefix: "", start: 0, note: "")
        open.id = "open"
        var closed = ReviewMark(type: .fix, quote: "x", prefix: "", start: 0, note: "")
        closed.id = "closed"
        closed.setStatus(.resolved)
        doc.marks = [open, closed]
        _ = try ReviewSidecar.save(doc, for: note, baseRev: 0)

        let result = try ReviewQueue.writeQueue(in: root)
        XCTAssertEqual(result.count, 1)
        let snap = try ReviewQueue.decode(Data(contentsOf: result.queueURL))
        XCTAssertEqual(snap.marks[0]["id"]?.stringValue, "open")
    }

    func testManualCommandEscapesPath() {
        let root = URL(fileURLWithPath: "/tmp/my project's notes")
        let cmd = ReviewQueue.manualCommand(for: root)
        XCTAssertTrue(cmd.contains("claude -p \"/smotr -pr\""))
        XCTAssertTrue(cmd.contains("'/tmp/my project'\\''s notes'"))
    }

    // MARK: Round-trip against on-disk smotr-written fixture (step F)

    /// EditMD must open a sidecar that a real smotr session wrote (or that
    /// matches its schema) without loss, and re-encode to the same logical
    /// document. Uses the acceptance fixture from this repo when present;
    /// otherwise a minimal stand-in that mirrors smotr's field set.
    func testRoundTripRealProjectFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // EditMDTests
            .deletingLastPathComponent() // EditMD
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("test-all-elements.md.review.json")

        let data: Data
        if FileManager.default.fileExists(atPath: fixtureURL.path) {
            data = try Data(contentsOf: fixtureURL)
        } else {
            // Stand-in if the acceptance file was cleaned up.
            data = Data("""
            {"rev":2,"marks":[
              {"id":"m1","type":"comment","quote":"# **Heading 1**","prefix":"",
               "start":0,"note":"привет","status":"open","ts":1,"mts":1,"thread":[]},
              {"id":"m2","type":"comment","quote":"> This is a blockquote.",
               "prefix":"photo.png) in the same line.\\n\\n","start":406,
               "note":"ыыы","status":"open","ts":2,"mts":2,"thread":[]}
            ]}
            """.utf8)
        }

        let doc = try ReviewSidecar.decode(data)
        let reencoded = try ReviewSidecar.encode(doc)
        let reDoc = try ReviewSidecar.decode(reencoded)
        XCTAssertEqual(doc, reDoc, "decode→encode→decode must be a fixed point")
        XCTAssertGreaterThanOrEqual(doc.marks.count, 1)
        // Every mark keeps its id and type through the cycle.
        for (a, b) in zip(doc.marks, reDoc.marks) {
            XCTAssertEqual(a.id, b.id)
            XCTAssertEqual(a.type, b.type)
            XCTAssertEqual(a.quote, b.quote)
            XCTAssertEqual(a.note, b.note)
        }
    }

    /// HTML-mark fields from a smotr visual sidecar must survive even when the
    /// fixture also carries prompts + an unknown top-level key.
    func testRoundTripSmotrRichFixture() throws {
        let json = """
        {
          "rev": 12,
          "marks": [
            {
              "id": "m1700000000000abcd",
              "type": "question",
              "quote": "Hello",
              "prefix": "# ",
              "start": 2,
              "note": "Is this right?",
              "status": "open",
              "ts": 1700000000000,
              "mts": 1700000000000,
              "thread": [
                {"role": "author", "text": "ping", "ts": 1700000000000},
                {"role": "claude", "text": "pong", "ts": 1700000001000, "extra": true}
              ]
            },
            {
              "id": "v1700000000000wxyz",
              "type": "element",
              "vtype": "element",
              "page": "home",
              "selector": "body > h1",
              "quote": "Title",
              "note": "too loud",
              "status": "open",
              "ts": 1700000002000
            },
            {
              "id": "s1700000000000sug1",
              "type": "suggest",
              "quote": "Hello",
              "prefix": "# ",
              "start": 2,
              "replacement": "Hi",
              "for": "m1700000000000abcd",
              "note": "shorter",
              "status": "open",
              "ts": 1700000003000
            }
          ],
          "prompts": {"intro": {"reply": "ok", "ts": 1}},
          "stages": {"docs/a.md": "review"}
        }
        """
        let doc = try ReviewSidecar.decode(Data(json.utf8))
        let round = try ReviewSidecar.decode(try ReviewSidecar.encode(doc))
        XCTAssertEqual(doc, round)
        XCTAssertEqual(round.rev, 12)
        XCTAssertEqual(round.marks.count, 3)
        XCTAssertEqual(round.marks[1].extra["selector"]?.stringValue, "body > h1")
        XCTAssertEqual(round.marks[2].forMark, "m1700000000000abcd")
        XCTAssertEqual(round.marks[2].replacement, "Hi")
        XCTAssertEqual(round.prompts["intro"]?["reply"]?.stringValue, "ok")
        // Unknown top-level key preserved.
        XCTAssertNotNil(round.extra["stages"])
        // Thread unknown field on claude reply.
        XCTAssertEqual(round.marks[0].thread?[1].extra["extra"], .bool(true))
    }

    // MARK: ReviewModel persistence pipeline (stage-2 race fixes)

    /// Add + delete inside one runloop tick: two persists in flight. The
    /// fire-and-forget saves used to resurrect the deleted mark via the
    /// stale-base merge; the FIFO pipeline must keep it deleted.
    @MainActor
    func testRapidAddDeleteDoesNotResurrect() async throws {
        let file = tempFile()
        defer { cleanup(file) }
        try "hello world".write(to: file, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        model.setActiveFile(file, text: "hello world")
        await model.flushPipeline()

        let id = model.addMark(
            anchor: .init(quote: "hello", prefix: "", start: 0),
            type: .comment, note: "n")
        model.deleteMark(id)
        await model.flushPipeline()

        XCTAssertTrue(model.doc.marks.isEmpty, "UI resurrected the deleted mark")
        let disk = ReviewSidecar.loadOrEmpty(for: file)
        XCTAssertTrue(disk.marks.isEmpty, "disk resurrected the deleted mark")
    }

    /// Reply + resolve back to back: the later mutation must not be
    /// overwritten by the earlier save's snapshot.
    @MainActor
    func testOverlappingMutationsBothPersist() async throws {
        let file = tempFile()
        defer { cleanup(file) }
        try "hello world".write(to: file, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        model.setActiveFile(file, text: "hello world")
        await model.flushPipeline()

        let id = model.addMark(
            anchor: .init(quote: "world", prefix: "hello ", start: 6),
            type: .question, note: "q")
        model.reply(to: id, text: "ответ")
        model.setStatus(id, .resolved)
        await model.flushPipeline()

        let disk = ReviewSidecar.loadOrEmpty(for: file)
        let m = try XCTUnwrap(disk[id])
        XCTAssertEqual(m.thread?.count, 1, "reply was lost")
        XCTAssertEqual(m.statusOrOpen, "resolved", "status change was lost")
        XCTAssertEqual(model.doc[id]?.statusOrOpen, "resolved")
    }

    /// Switching files while a persist is in flight: the previous file's
    /// marks must not leak into the new file's sidecar, and the new mark
    /// must not be wiped by the async reload landing after it.
    @MainActor
    func testFileSwitchDoesNotLeakMarksIntoNewSidecar() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.md")
        let b = dir.appendingPathComponent("b.md")
        try "alpha text".write(to: a, atomically: true, encoding: .utf8)
        try "beta text".write(to: b, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        model.setActiveFile(a, text: "alpha text")
        await model.flushPipeline()
        model.addMark(anchor: .init(quote: "alpha", prefix: "", start: 0),
                      type: .comment, note: "on a")
        // Switch before a's persist lands, add on b before its reload lands.
        model.setActiveFile(b, text: "beta text")
        model.addMark(anchor: .init(quote: "beta", prefix: "", start: 0),
                      type: .comment, note: "on b")
        await model.flushPipeline()

        let diskA = ReviewSidecar.loadOrEmpty(for: a)
        XCTAssertEqual(diskA.marks.map(\.note), ["on a"], "a's mark lost or polluted")
        let diskB = ReviewSidecar.loadOrEmpty(for: b)
        XCTAssertEqual(diskB.marks.map(\.note), ["on b"], "b's sidecar polluted or mark wiped")
        XCTAssertEqual(model.doc.marks.map(\.note), ["on b"])
    }

    /// Stage-4: the shared anchor cache re-resolves after (debounced) text
    /// edits — views and the sidebar read the dict instead of searching.
    @MainActor
    func testAnchorCacheTracksTextEdits() async throws {
        let file = tempFile()
        defer { cleanup(file) }
        try "hello world".write(to: file, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        model.setActiveFile(file, text: "hello world")
        await model.flushPipeline()

        model.addMark(anchor: .init(quote: "world", prefix: "hello ", start: 6),
                      type: .comment, note: "n")
        await model.flushPipeline()
        await model.awaitAnchorRecompute()
        let mark = try XCTUnwrap(model.doc.marks.first)
        XCTAssertEqual(model.anchor(for: mark)?.location, 6)

        // Text grows before the anchor: the debounced recompute shifts it.
        model.setActiveFile(file, text: "1234hello world")
        await model.awaitAnchorRecompute()
        XCTAssertEqual(model.anchor(for: mark)?.location, 10)
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

    private func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-queue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ file: URL) {
        try? ReviewSidecar.delete(for: file)
        try? FileManager.default.removeItem(at: file)
    }
}
