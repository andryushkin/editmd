import Testing
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

    @MainActor
    func testComposeRequestIsConsumedExactlyOnce() {
        let model = ReviewModel()

        XCTAssertFalse(model.consumeComposeRequest())
        model.requestCompose()
        XCTAssertTrue(model.consumeComposeRequest())
        XCTAssertFalse(model.consumeComposeRequest())

        model.requestCompose()
        XCTAssertTrue(model.consumeComposeRequest())
    }

    @MainActor
    func testComposeNoteResetsOnlyWhenAnchorChanges() {
        let first = ReviewModel.CapturedAnchor(quote: "one", prefix: "", start: 0)
        let second = ReviewModel.CapturedAnchor(quote: "two", prefix: "one ", start: 4)

        XCTAssertFalse(ReviewSidebar.shouldResetComposeNote(previous: first, next: first))
        XCTAssertTrue(ReviewSidebar.shouldResetComposeNote(previous: first, next: second))
        XCTAssertTrue(ReviewSidebar.shouldResetComposeNote(previous: first, next: nil))
    }

    @MainActor
    func testReviewBridgeUsesMostRecentNonEmptySelection() throws {
        let bridge = ClaudeIDEBridge.shared
        let file = URL(fileURLWithPath: "/tmp/editmd-split-review-selection.md")
        let markdown = "left and right"
        bridge.resetForTesting()
        bridge.setActiveURL(file)
        defer { bridge.resetForTesting() }

        // In Split, Source reports first, then Preview becomes the latest.
        bridge.noteSelection(url: file, markdownRange: NSRange(location: 0, length: 4),
                             markdown: markdown)
        bridge.noteSelection(url: file, markdownRange: NSRange(location: 9, length: 5),
                             markdown: markdown)
        var selected = try XCTUnwrap(bridge.reviewSelectionSource())
        XCTAssertEqual(selected.range, NSRange(location: 9, length: 5))

        // A new Source selection takes ownership back from Preview.
        bridge.noteSelection(url: file, markdownRange: NSRange(location: 5, length: 3),
                             markdown: markdown)
        selected = try XCTUnwrap(bridge.reviewSelectionSource())
        XCTAssertEqual(selected.range, NSRange(location: 5, length: 3))
    }

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

    // MARK: UTF-16 anchor arithmetic (stage-5 — smotr-JS offset semantics)

    /// Prefix ends with a base letter, quote begins with a combining accent —
    /// smotr's JS slices at UTF-16 boundaries, so this is a legal sidecar.
    /// Grapheme (Character) stepping merged "e" + accent into one cluster and
    /// shifted the anchor by a scalar; UTF-16 math must return it exactly.
    func testAnchorRangeCombiningMarkBoundary() throws {
        let text = "abc xye\u{0301}той hvost"
        let r = try XCTUnwrap(ReviewSidecar.anchorRange(
            quote: "\u{0301}той", prefix: "abc xye", start: 7, in: text))
        XCTAssertEqual(String(text[r]), "\u{0301}той")
        let ns = NSRange(r, in: text)
        XCTAssertEqual(ns.location, 7)
        XCTAssertEqual(ns.length, 4)
    }

    /// `start` is stored in UTF-16 code units (smotr's JS string indices) —
    /// grapheme counts drift on any document with emoji.
    func testCaptureAnchorStartIsUTF16Units() throws {
        let text = "🙂🙂 hello world"
        let range = try XCTUnwrap(text.range(of: "world"))
        let a = ReviewSidecar.captureAnchor(in: text, range: range)
        XCTAssertEqual(a.start, (text as NSString).range(of: "world").location)  // 11, not 9
        XCTAssertEqual(a.quote, "world")
        XCTAssertEqual(a.prefix, "🙂🙂 hello ")
        // And it round-trips through anchorRange.
        XCTAssertEqual(ReviewSidecar.anchorRange(
            quote: a.quote, prefix: a.prefix, start: a.start, in: text), range)
    }

    /// The 30-unit prefix window must not split a surrogate pair at its edge.
    func testCapturePrefixWindowDoesNotSplitSurrogates() throws {
        let text = "a" + String(repeating: "🙂", count: 20) + "b" + "target"
        let range = try XCTUnwrap(text.range(of: "target"))
        let a = ReviewSidecar.captureAnchor(in: text, range: range)
        XCTAssertFalse(a.prefix.unicodeScalars.contains { $0.value == 0xFFFD },
                       "prefix contains a broken surrogate")
        XCTAssertTrue(a.prefix.hasSuffix("b"))
        XCTAssertEqual(ReviewSidecar.anchorRange(
            quote: a.quote, prefix: a.prefix, start: a.start, in: text), range)
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

@Suite("ReviewModel path coordination")
@MainActor
struct ReviewModelPathMutationTests {

    @Test("path barrier drains saves for a file that is no longer active")
    func barrierDrainsGlobalPipeline() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "first text".write(to: first, atomically: true, encoding: .utf8)
        try "second text".write(to: second, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        model.setActiveFile(first, text: "first text")
        model.addMark(anchor: .init(quote: "first", prefix: "", start: 0),
                      type: .comment, note: "belongs to first")
        model.setActiveFile(second, text: "second text")

        let token = await model.beginPathMutation()
        model.cancelPathMutation(token)

        let disk = try #require(try ReviewSidecar.load(for: first))
        #expect(disk.marks.map(\.note) == ["belongs to first"])
    }

    @Test("deferred save follows an exact file move")
    func deferredPersistFollowsFileMove() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder,
                                                withIntermediateDirectories: true)
        let oldFile = sourceFolder.appendingPathComponent("note.md")
        let newFile = destinationFolder.appendingPathComponent("note.md")
        try "hello".write(to: oldFile, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        model.setActiveFile(oldFile, text: "hello")
        await model.flushPipeline()
        let id = model.addMark(anchor: .init(quote: "hello", prefix: "", start: 0),
                               type: .comment, note: "move me")
        await model.flushPipeline()

        let token = await model.beginPathMutation()
        model.reply(to: id, text: "written behind the barrier")
        try FileManager.default.moveItem(at: oldFile, to: newFile)
        try FileManager.default.moveItem(at: ReviewSidecar.url(for: oldFile),
                                         to: ReviewSidecar.url(for: newFile))
        model.completePathMutation(
            token,
            relocatingFiles: [.init(from: oldFile, to: newFile)]
        )
        await model.flushPipeline()

        #expect(model.fileURL == newFile.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: ReviewSidecar.url(for: oldFile).path))
        let disk = try #require(try ReviewSidecar.load(for: newFile))
        #expect(disk[id]?.thread?.count == 1)
        #expect(disk[id]?.thread?.first?.text == "written behind the barrier")
    }

    @Test("deferred save follows a root rename without recreating the old root")
    func deferredPersistFollowsFolderRename() async throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldRoot = parent.appendingPathComponent("Old Root", isDirectory: true)
        let newRoot = parent.appendingPathComponent("New Root", isDirectory: true)
        let oldFolder = oldRoot.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: oldFolder,
                                                withIntermediateDirectories: true)
        let oldFile = oldFolder.appendingPathComponent("note.md")
        try "hello".write(to: oldFile, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        model.setActiveFile(oldFile, text: "hello")
        await model.flushPipeline()
        let id = model.addMark(anchor: .init(quote: "hello", prefix: "", start: 0),
                               type: .comment, note: "rename me")
        await model.flushPipeline()

        let token = await model.beginPathMutation()
        model.setStatus(id, .resolved)
        try FileManager.default.moveItem(at: oldRoot, to: newRoot)
        model.completePathMutation(token, relocatingFolderFrom: oldRoot, to: newRoot)
        await model.flushPipeline()

        let newFile = newRoot.appendingPathComponent("docs/note.md")
        #expect(model.fileURL == newFile.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: oldRoot.path))
        let disk = try #require(try ReviewSidecar.load(for: newFile))
        #expect(disk[id]?.statusOrOpen == "resolved")
    }

    @Test("inactive control mark follows an exact file move")
    func inactiveControlMarkFollowsExactMove() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        let destinationFolder = root.appendingPathComponent(
            "destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destinationFolder, withIntermediateDirectories: true)
        let oldFile = sourceFolder.appendingPathComponent("note.md")
        let newFile = destinationFolder.appendingPathComponent("note.md")
        try "hello".write(to: oldFile, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        let token = await model.beginPathMutation()
        let mark = ReviewMark(
            type: .comment, quote: "hello", prefix: "", start: 0,
            note: "control exact")
        let ticket = model.enqueueControlMarkWrite(mark, for: oldFile)

        try FileManager.default.moveItem(at: oldFile, to: newFile)
        model.completePathMutation(
            token,
            relocatingFiles: [.init(from: oldFile, to: newFile)])

        let outcome = try #require(await waitForTicket(ticket))
        let written = try outcome.get()
        #expect(written.url == newFile.standardizedFileURL)
        #expect(written.markID == mark.id)
        #expect(!FileManager.default.fileExists(
            atPath: ReviewSidecar.url(for: oldFile).path))
        let disk = try #require(try ReviewSidecar.load(for: newFile))
        #expect(disk[mark.id]?.note == "control exact")
        #expect(written.rev == disk.rev)
    }

    @Test("inactive control mark follows a root rename")
    func inactiveControlMarkFollowsRootRename() async throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldRoot = parent.appendingPathComponent("Old", isDirectory: true)
        let newRoot = parent.appendingPathComponent("New", isDirectory: true)
        let oldFolder = oldRoot.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: oldFolder, withIntermediateDirectories: true)
        let oldFile = oldFolder.appendingPathComponent("note.md")
        try "hello".write(to: oldFile, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        let token = await model.beginPathMutation()
        let mark = ReviewMark(
            type: .comment, quote: "hello", prefix: "", start: 0,
            note: "control root")
        let ticket = model.enqueueControlMarkWrite(mark, for: oldFile)
        let readTicket = model.enqueueControlMarksRead(for: oldFile)

        try FileManager.default.moveItem(at: oldRoot, to: newRoot)
        model.completePathMutation(
            token, relocatingFolderFrom: oldRoot, to: newRoot)

        let outcome = try #require(await waitForTicket(ticket))
        let written = try outcome.get()
        let readOutcome = try #require(await waitForTicket(readTicket))
        let read = try readOutcome.get()
        let newFile = newRoot.appendingPathComponent("docs/note.md")
        #expect(written.url == newFile.standardizedFileURL)
        #expect(read.url == newFile.standardizedFileURL)
        #expect(read.doc[mark.id]?.note == "control root")
        #expect(!FileManager.default.fileExists(atPath: oldRoot.path))
        let disk = try #require(try ReviewSidecar.load(for: newFile))
        #expect(disk[mark.id]?.note == "control root")
        #expect(written.rev == disk.rev)
    }

    @Test("combined root outcome relocates source actions and drops expected-root actions")
    func combinedRootOutcomeRelocatesAndDrops() async throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldRoot = parent.appendingPathComponent("Old", isDirectory: true)
        let survivorRoot = parent.appendingPathComponent("Recovered", isDirectory: true)
        let expectedRoot = parent.appendingPathComponent("Expected", isDirectory: true)
        let oldFile = oldRoot.appendingPathComponent("docs/note.md")
        let expectedFile = expectedRoot.appendingPathComponent("docs/note.md")
        try FileManager.default.createDirectory(
            at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "hello".write(to: oldFile, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        let token = await model.beginPathMutation()
        let mark = ReviewMark(
            type: .comment, quote: "hello", prefix: "", start: 0,
            note: "survives rollback")
        let sourceTicket = model.enqueueControlMarkWrite(mark, for: oldFile)
        let expectedTicket = model.enqueueControlMarksRead(for: expectedFile)

        try FileManager.default.moveItem(at: oldRoot, to: survivorRoot)
        model.completePathMutation(
            token,
            relocatingFolderFrom: oldRoot,
            to: survivorRoot,
            droppingFoldersAt: [expectedRoot])

        let sourceOutcome = try #require(await waitForTicket(sourceTicket))
        let written = try sourceOutcome.get()
        let survivorFile = survivorRoot.appendingPathComponent("docs/note.md")
        #expect(written.url == survivorFile.standardizedFileURL)
        let expectedOutcome = try #require(await waitForTicket(expectedTicket))
        #expect(expectedOutcome == .failure(.pathUnavailable(
            expectedFile.standardizedFileURL)))
        #expect(!FileManager.default.fileExists(atPath: expectedRoot.path))
        let disk = try #require(try ReviewSidecar.load(for: survivorFile))
        #expect(disk[mark.id]?.note == "survives rollback")
    }

    @Test("file rollback keeps source actions and drops future-destination actions")
    func exactRollbackKeepsSourceAndDropsDestination() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.md")
        let destination = root.appendingPathComponent("destination.md")
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        let token = await model.beginPathMutation()
        let mark = ReviewMark(
            type: .comment, quote: "hello", prefix: "", start: 0,
            note: "stays at source")
        let sourceTicket = model.enqueueControlMarkWrite(mark, for: source)
        let destinationTicket = model.enqueueControlMarksRead(for: destination)

        model.completePathMutation(
            token,
            relocatingFiles: [],
            droppingFiles: [destination])

        let sourceOutcome = try #require(await waitForTicket(sourceTicket))
        let written = try sourceOutcome.get()
        #expect(written.url == source.standardizedFileURL)
        let destinationOutcome = try #require(
            await waitForTicket(destinationTicket))
        #expect(destinationOutcome == .failure(.pathUnavailable(
            destination.standardizedFileURL)))
        let disk = try #require(try ReviewSidecar.load(for: source))
        #expect(disk[mark.id]?.note == "stays at source")
        #expect(!FileManager.default.fileExists(
            atPath: ReviewSidecar.url(for: destination).path))
    }

    @Test("path mutations acquire the shared barrier in FIFO order")
    func pathMutationsAreSerializedInFIFOOrder() async {
        let model = ReviewModel()
        let first = await model.beginPathMutation()
        let (started, signal) = AsyncStream.makeStream(of: Int.self)
        var iterator = started.makeAsyncIterator()
        var acquisitionOrder: [Int] = []

        let second = Task { @MainActor in
            signal.yield(2)
            let token = await model.beginPathMutation()
            acquisitionOrder.append(2)
            model.cancelPathMutation(token)
        }
        let secondStart = await iterator.next()
        #expect(secondStart == 2)

        let third = Task { @MainActor in
            signal.yield(3)
            let token = await model.beginPathMutation()
            acquisitionOrder.append(3)
            model.cancelPathMutation(token)
        }
        let thirdStart = await iterator.next()
        #expect(thirdStart == 3)

        model.cancelPathMutation(first)
        await second.value
        await third.value
        signal.finish()

        #expect(acquisitionOrder == [2, 3])
    }

    @Test("unresolved path drops deferred sidecar work")
    func unresolvedPathDoesNotRecreateSidecar() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        model.setActiveFile(file, text: "hello")
        await model.flushPipeline()
        let id = model.addMark(
            anchor: .init(quote: "hello", prefix: "", start: 0),
            type: .comment,
            note: "before failure")
        await model.flushPipeline()

        let token = await model.beginPathMutation()
        model.reply(to: id, text: "must be discarded")
        try ReviewSidecar.delete(for: file)
        try FileManager.default.removeItem(at: file)
        model.completePathMutation(
            token,
            relocatingFiles: [],
            droppingFiles: [file])
        await model.flushPipeline()

        #expect(model.fileURL == nil)
        #expect(model.doc.marks.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: ReviewSidecar.url(for: file).path))
    }

    @Test("ambiguous root drop rejects control marks and does not recreate either root")
    func ambiguousRootDropRejectsTicketsWithoutRecreatingRoots() async throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldRoot = parent.appendingPathComponent("Old", isDirectory: true)
        let expectedRoot = parent.appendingPathComponent("Expected", isDirectory: true)
        let oldFile = oldRoot.appendingPathComponent("docs/note.md")
        let expectedFile = expectedRoot.appendingPathComponent("docs/note.md")
        try FileManager.default.createDirectory(
            at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: expectedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: oldFile, atomically: true, encoding: .utf8)
        try "expected".write(to: expectedFile, atomically: true, encoding: .utf8)

        let model = ReviewModel()
        model.setActiveFile(oldFile, text: "old")
        await model.flushPipeline()
        let activeID = model.addMark(
            anchor: .init(quote: "old", prefix: "", start: 0),
            type: .comment,
            note: "before ambiguous rename")
        await model.flushPipeline()

        let token = await model.beginPathMutation()
        model.reply(to: activeID, text: "must be discarded")
        let oldMark = ReviewMark(
            type: .comment, quote: "old", prefix: "", start: 0,
            note: "old control")
        let expectedMark = ReviewMark(
            type: .comment, quote: "expected", prefix: "", start: 0,
            note: "expected control")
        let oldTicket = model.enqueueControlMarkWrite(oldMark, for: oldFile)
        let expectedTicket = model.enqueueControlMarkWrite(
            expectedMark, for: expectedFile)
        let oldReadTicket = model.enqueueControlMarksRead(for: oldFile)
        let expectedReadTicket = model.enqueueControlMarksRead(for: expectedFile)

        try FileManager.default.removeItem(at: oldRoot)
        try FileManager.default.removeItem(at: expectedRoot)
        model.completePathMutation(
            token,
            droppingFoldersAt: [oldRoot, expectedRoot])

        let oldOutcome = try #require(await waitForTicket(oldTicket))
        let expectedOutcome = try #require(await waitForTicket(expectedTicket))
        let oldReadOutcome = try #require(await waitForTicket(oldReadTicket))
        let expectedReadOutcome = try #require(await waitForTicket(expectedReadTicket))
        #expect(oldOutcome == .failure(.pathUnavailable(
            oldFile.standardizedFileURL)))
        #expect(expectedOutcome == .failure(.pathUnavailable(
            expectedFile.standardizedFileURL)))
        #expect(oldReadOutcome == .failure(.pathUnavailable(
            oldFile.standardizedFileURL)))
        #expect(expectedReadOutcome == .failure(.pathUnavailable(
            expectedFile.standardizedFileURL)))
        await model.flushPipeline()

        #expect(model.fileURL == nil)
        #expect(model.doc.marks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: oldRoot.path))
        #expect(!FileManager.default.fileExists(atPath: expectedRoot.path))
    }

    private func waitForTicket<Success: Sendable>(
        _ ticket: ReviewControlTicket<Success>
    ) async -> ReviewControlTicket<Success>.Outcome? {
        await Task.detached {
            ticket.wait(timeout: .now() + 2)
        }.value
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-review-path-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
