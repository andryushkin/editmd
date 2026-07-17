import Foundation

// Review marks — smotr-compatible sidecar model (phase 2, v37).
//
// A "mark" is a review thread anchored to a text fragment. Marks live in a
// sidecar `<file>.md.review.json` NEXT TO the file; the original is never
// touched (only accepted `suggest` edits rewrite the file, via the registry).
//
// The format is smotr's (~/Server/smotr) — EditMD is a *second* frontend for
// the very same marks, so a sidecar written here must open in the smotr web
// view without loss, and vice-versa. Two consequences drive the design:
//
//   1. Fidelity: every field we do not model (html-mark `selector`/`vtype`,
//      future schema additions) is preserved verbatim through an `extra` bag.
//      We only ever *add* known fields we set; we never drop what we read.
//   2. Anchors are computed against the RAW markdown (EditMD's source of
//      truth), matching smotr's own apply path (`_apply_suggest` rewrites the
//      raw file). Best-effort `quote`+`prefix` resolution with an honest
//      `needs-rebase` when the fragment is gone — never "approximately there".
//
// Pure value types + Foundation only: no AppKit, no actor isolation. The UI
// model (`ReviewModel`) and the sidebar sit on top.

// MARK: - Vocabulary

/// Author intent for a mark. Claude processes open marks by this priority
/// (`question → fix → rewrite → cut`), matching smotr's `_TYPE_PRIORITY`.
enum ReviewMarkType: String, CaseIterable {
    case question   // blocking question (processed first)
    case fix        // fact / correctness
    case rewrite    // tone / clarity
    case cut        // remove the fragment
    case keep       // "do not touch" — wording is final
    case comment    // neutral note
    case suggest    // Claude's track-changes edit (quote → replacement)

    /// Processing priority (lower = sooner); unknown types sort last.
    var priority: Int {
        switch self {
        case .question: return 0
        case .fix: return 1
        case .rewrite: return 2
        case .cut: return 3
        default: return 4
        }
    }

    var glyph: String {
        switch self {
        case .question: return "questionmark.circle"
        case .fix: return "checkmark.seal"
        case .rewrite: return "pencil"
        case .cut: return "scissors"
        case .keep: return "lock"
        case .comment: return "bubble.left"
        case .suggest: return "wand.and.stars"
        }
    }

    var label: String {
        switch self {
        case .question: return String(localized: "Question")
        case .fix: return String(localized: "Fact")
        case .rewrite: return String(localized: "Rewrite")
        case .cut: return String(localized: "Cut Out")
        case .keep: return String(localized: "Keep")
        case .comment: return String(localized: "Note")
        case .suggest: return String(localized: "Suggestion")
        }
    }
}

extension Notification.Name {
    /// Posted after `ReviewModel` adopts a new sidecar snapshot (load / save /
    /// mutation). Source and Visual re-paint open-mark anchors from it.
    static let reviewMarksDidChange = Notification.Name("editMD.reviewMarksDidChange")
}

/// One resolved open-mark anchor ready for in-text highlighting (UTF-16 range
/// into the raw markdown buffer).
struct ReviewAnchorHighlight: Equatable, Sendable {
    let id: String
    let range: NSRange
    let type: ReviewMarkType?
    let tooltip: String
}

/// Thread lifecycle status. Absent status means `open` (smotr convention).
enum ReviewMarkStatus: String {
    case open
    case resolved
    case wontfix
    case needsInfo = "needs-info"
    case needsRebase = "needs-rebase"
}

// MARK: - Thread entry

/// One reply on a mark's thread. smotr writes `{role, text, ts}`; unknown
/// fields are preserved so a richer engine round-trips through us untouched.
struct ReviewThreadEntry: Equatable {
    var role: String        // "author" | "claude"
    var text: String
    var ts: Int64?
    var extra: [String: JSONValue] = [:]

    init(role: String, text: String, ts: Int64? = nil, extra: [String: JSONValue] = [:]) {
        self.role = role
        self.text = text
        self.ts = ts
        self.extra = extra
    }
}

extension ReviewThreadEntry: Codable {
    private static let known: Set<String> = ["role", "text", "ts"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ReviewCodingKey.self)
        role = try c.decodeIfPresent(String.self, forKey: ReviewCodingKey("role")) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: ReviewCodingKey("text")) ?? ""
        ts = try c.decodeIfPresent(Int64.self, forKey: ReviewCodingKey("ts"))
        var e: [String: JSONValue] = [:]
        for k in c.allKeys where !Self.known.contains(k.stringValue) {
            e[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        extra = e
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ReviewCodingKey.self)
        try c.encode(role, forKey: ReviewCodingKey("role"))
        try c.encode(text, forKey: ReviewCodingKey("text"))
        try c.encodeIfPresent(ts, forKey: ReviewCodingKey("ts"))
        for (k, v) in extra { try c.encode(v, forKey: ReviewCodingKey(k)) }
    }
}

// MARK: - Mark

/// A single review mark. Known fields are typed for ergonomic UI access; the
/// `extra` bag carries everything else verbatim (html marks store
/// `vtype`/`page`/`selector` there, and any future smotr field lands there too).
///
/// Fields are optional and encoded only when present, so a decode→encode cycle
/// neither drops nor invents fields — the smotr contract is "no loss".
struct ReviewMark: Equatable {
    var id: String
    var type: String
    var quote: String?
    var prefix: String?
    var start: Int?
    var note: String?
    var replacement: String?    // suggest only
    var forMark: String?        // JSON key "for": suggest → source mark id
    var status: String?         // absent == open
    var ts: Int64?
    var mts: Int64?
    var applied: Int64?         // suggest applied timestamp (ms)
    var thread: [ReviewThreadEntry]?
    var extra: [String: JSONValue] = [:]

    // MARK: Derived

    var markType: ReviewMarkType? { ReviewMarkType(rawValue: type) }
    var statusOrOpen: String { status ?? ReviewMarkStatus.open.rawValue }
    var isOpen: Bool { statusOrOpen == ReviewMarkStatus.open.rawValue }
    var isSuggestion: Bool { type == ReviewMarkType.suggest.rawValue }
    /// Processing priority for the worklist (matches smotr `_TYPE_PRIORITY`).
    var priority: Int { markType?.priority ?? 4 }
}

extension ReviewMark {
    /// One-line tooltip for the in-text wash — shared by Source, Visual and
    /// Preview so the three surfaces describe a mark identically.
    var washTooltip: String {
        if isSuggestion, let replacement {
            return "suggest: \(replacement)"
        }
        if let note, !note.isEmpty {
            return "\(markType?.label ?? type): \(note)"
        }
        return markType?.label ?? type
    }

    /// A fresh author-created mark (EditMD only ever creates markdown marks:
    /// quote + prefix + start, anchored in the raw text).
    init(type: ReviewMarkType, quote: String, prefix: String, start: Int, note: String) {
        let now = ReviewClock.nowMillis()
        self.id = ReviewSidecar.newMarkID(at: now)
        self.type = type.rawValue
        self.quote = quote
        self.prefix = prefix
        self.start = start
        self.note = note.isEmpty ? nil : note
        self.status = ReviewMarkStatus.open.rawValue
        self.ts = now
        self.mts = now
        self.thread = []
    }

    /// Appends a thread reply and bumps `mts`.
    mutating func appendReply(role: String, text: String, at ts: Int64 = ReviewClock.nowMillis()) {
        var t = thread ?? []
        t.append(ReviewThreadEntry(role: role, text: text, ts: ts))
        thread = t
        mts = ts
    }

    mutating func setStatus(_ status: ReviewMarkStatus, at ts: Int64 = ReviewClock.nowMillis()) {
        self.status = status.rawValue
        self.mts = ts
    }
}

extension ReviewMark: Codable {
    private static let known: Set<String> = [
        "id", "type", "quote", "prefix", "start", "note", "replacement",
        "for", "status", "ts", "mts", "applied", "thread",
    ]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ReviewCodingKey.self)
        func s(_ k: String) throws -> String? {
            try c.decodeIfPresent(String.self, forKey: ReviewCodingKey(k))
        }
        id = try s("id") ?? ""
        type = try s("type") ?? ReviewMarkType.comment.rawValue
        quote = try s("quote")
        prefix = try s("prefix")
        start = try c.decodeIfPresent(Int.self, forKey: ReviewCodingKey("start"))
        note = try s("note")
        replacement = try s("replacement")
        forMark = try s("for")
        status = try s("status")
        ts = try c.decodeIfPresent(Int64.self, forKey: ReviewCodingKey("ts"))
        mts = try c.decodeIfPresent(Int64.self, forKey: ReviewCodingKey("mts"))
        applied = try c.decodeIfPresent(Int64.self, forKey: ReviewCodingKey("applied"))
        thread = try c.decodeIfPresent([ReviewThreadEntry].self, forKey: ReviewCodingKey("thread"))
        var e: [String: JSONValue] = [:]
        for k in c.allKeys where !Self.known.contains(k.stringValue) {
            e[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        extra = e
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ReviewCodingKey.self)
        try c.encode(id, forKey: ReviewCodingKey("id"))
        try c.encode(type, forKey: ReviewCodingKey("type"))
        try c.encodeIfPresent(quote, forKey: ReviewCodingKey("quote"))
        try c.encodeIfPresent(prefix, forKey: ReviewCodingKey("prefix"))
        try c.encodeIfPresent(start, forKey: ReviewCodingKey("start"))
        try c.encodeIfPresent(note, forKey: ReviewCodingKey("note"))
        try c.encodeIfPresent(replacement, forKey: ReviewCodingKey("replacement"))
        try c.encodeIfPresent(forMark, forKey: ReviewCodingKey("for"))
        try c.encodeIfPresent(status, forKey: ReviewCodingKey("status"))
        try c.encodeIfPresent(ts, forKey: ReviewCodingKey("ts"))
        try c.encodeIfPresent(mts, forKey: ReviewCodingKey("mts"))
        try c.encodeIfPresent(applied, forKey: ReviewCodingKey("applied"))
        try c.encodeIfPresent(thread, forKey: ReviewCodingKey("thread"))
        for (k, v) in extra { try c.encode(v, forKey: ReviewCodingKey(k)) }
    }
}

// MARK: - Document (sidecar contents)

/// The whole sidecar: `{rev, marks, prompts}`. `rev` is the optimistic
/// concurrency counter (browser and Claude and EditMD all write the same file).
struct ReviewDocument: Equatable {
    var rev: Int = 0
    var marks: [ReviewMark] = []
    /// Fenced-prompt cards keyed by heading anchor — smotr's feature; EditMD
    /// preserves but does not create them.
    var prompts: [String: JSONValue] = [:]
    var extra: [String: JSONValue] = [:]

    var openMarks: [ReviewMark] { marks.filter { $0.isOpen } }
    var openCount: Int { openMarks.count }

    /// Marks ordered for the worklist: by processing priority, then recency.
    var worklist: [ReviewMark] {
        marks.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return ($0.ts ?? 0) < ($1.ts ?? 0)
        }
    }

    mutating func upsert(_ mark: ReviewMark) {
        if let i = marks.firstIndex(where: { $0.id == mark.id }) {
            marks[i] = mark
        } else {
            marks.append(mark)
        }
    }

    subscript(id: String) -> ReviewMark? {
        get { marks.first { $0.id == id } }
        set {
            guard let nv = newValue else {
                marks.removeAll { $0.id == id }
                return
            }
            upsert(nv)
        }
    }
}

extension ReviewDocument: Codable {
    private static let known: Set<String> = ["rev", "marks", "prompts"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ReviewCodingKey.self)
        rev = try c.decodeIfPresent(Int.self, forKey: ReviewCodingKey("rev")) ?? 0
        marks = try c.decodeIfPresent([ReviewMark].self, forKey: ReviewCodingKey("marks")) ?? []
        prompts = try c.decodeIfPresent([String: JSONValue].self, forKey: ReviewCodingKey("prompts")) ?? [:]
        var e: [String: JSONValue] = [:]
        for k in c.allKeys where !Self.known.contains(k.stringValue) {
            e[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        extra = e
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ReviewCodingKey.self)
        try c.encode(rev, forKey: ReviewCodingKey("rev"))
        try c.encode(marks, forKey: ReviewCodingKey("marks"))
        if !prompts.isEmpty { try c.encode(prompts, forKey: ReviewCodingKey("prompts")) }
        for (k, v) in extra { try c.encode(v, forKey: ReviewCodingKey(k)) }
    }
}

// MARK: - Dynamic coding key

/// A string key for keyed containers, so unknown JSON fields can be enumerated.
struct ReviewCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue s: String) { stringValue = s }
    init?(intValue: Int) { nil }
}

// MARK: - Clock (injectable for tests)

enum ReviewClock {
    /// Overridable in tests for deterministic ids/timestamps.
    nonisolated(unsafe) static var now: () -> Date = { Date() }
    static func nowMillis() -> Int64 { Int64(now().timeIntervalSince1970 * 1000) }
}

// MARK: - Sidecar IO + anchors

enum ReviewSidecar {

    // MARK: Path

    /// `note.md` → `note.md.review.json` (smotr's `path + ".review.json"`).
    static func url(for file: URL) -> URL {
        file.deletingLastPathComponent()
            .appendingPathComponent(file.lastPathComponent + ".review.json")
    }

    // MARK: Load

    /// Returns nil when no sidecar exists yet.
    static func load(for file: URL) throws -> ReviewDocument? {
        let path = url(for: file)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        return try decode(data)
    }

    static func loadOrEmpty(for file: URL) -> ReviewDocument {
        (try? load(for: file)) ?? ReviewDocument()
    }

    static func decode(_ data: Data) throws -> ReviewDocument {
        try JSONDecoder().decode(ReviewDocument.self, from: data)
    }

    // MARK: Save (optimistic rev-guard, merge by id)

    /// Persists `doc` for `file`, reconciling with whatever is on disk now.
    ///
    /// Because EditMD edits the sidecar directly (not through smotr's HTTP
    /// endpoint), it plays the role smotr's server documents for out-of-band
    /// writers: read the current disk `rev`; if another writer advanced it,
    /// merge our marks by `id` onto the disk state rather than clobbering it;
    /// always write `rev = diskRev + 1`.
    ///
    /// Returns the document actually written (with the bumped rev + merged
    /// marks) so the caller can adopt it as its new base.
    @discardableResult
    static func save(_ doc: ReviewDocument, for file: URL, baseRev: Int) throws -> ReviewDocument {
        let path = url(for: file)
        let disk = try load(for: file)
        var out = doc

        if let disk, disk.rev != baseRev {
            // Someone advanced the file since we loaded: start from disk and
            // re-apply our marks by id (whole-mark, like smotr's client merge).
            var merged = disk
            for m in doc.marks { merged.upsert(m) }
            merged.prompts.merge(doc.prompts) { _, mine in mine }
            merged.extra.merge(doc.extra) { disk, _ in disk }
            out = merged
        }

        out.rev = (disk?.rev ?? baseRev) + 1
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(out).write(to: path, options: .atomic)
        return out
    }

    static func encode(_ doc: ReviewDocument) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(doc)
    }

    /// Deletes the sidecar (e.g. no marks left) — no-op if absent.
    static func delete(for file: URL) throws {
        let path = url(for: file)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    // MARK: Id generation

    /// `m` + epoch-millis + 4 base-36 chars, matching smotr's markdown ids
    /// (`'m' + Date.now() + Math.random().toString(36).slice(2,6)`).
    static func newMarkID(at millis: Int64 = ReviewClock.nowMillis()) -> String {
        "m\(millis)\(randomBase36(4))"
    }

    private static func randomBase36(_ n: Int) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<n).map { _ in alphabet.randomElement()! })
    }

    // MARK: Anchor resolution (port of smotr `_find_anchor`)

    /// Locates the mark's `quote` in `text`, trying, in order: `prefix+quote`
    /// (exact context), `quote` near the stored `start` offset, then `quote`
    /// anywhere. Returns the range of the quote, or nil when the fragment is
    /// gone (→ honest `needs-rebase`, never "approximately there").
    ///
    /// All arithmetic is UTF-16 code units with `.literal` search — the same
    /// semantics as smotr's JS `indexOf`/slice offsets. Character (grapheme)
    /// math skids when the prefix/quote boundary merges into one cluster
    /// (e.g. prefix ends "e", quote starts with a combining accent): stepping
    /// `prefix.count` Characters overshot and silently shifted the anchor —
    /// wash on the wrong range, applySuggest corrupting the document.
    static func anchorRange(quote: String, prefix: String, start: Int,
                            in text: String) -> Range<String.Index>? {
        guard !quote.isEmpty else { return nil }
        let ns = text as NSString

        if !prefix.isEmpty {
            let ctx = ns.range(of: prefix + quote, options: [.literal])
            if ctx.location != NSNotFound {
                let quoteRange = NSRange(
                    location: ctx.location + (prefix as NSString).length,
                    length: (quote as NSString).length)
                return Range(quoteRange, in: text)
            }
        }
        // Search near the stored offset first (start − 40, like smotr).
        let hint = max(0, start - 40)
        if hint > 0, hint < ns.length {
            let r = ns.range(of: quote, options: [.literal],
                             range: NSRange(location: hint, length: ns.length - hint))
            if r.location != NSNotFound { return Range(r, in: text) }
        }
        let global = ns.range(of: quote, options: [.literal])
        return global.location != NSNotFound ? Range(global, in: text) : nil
    }

    static func anchorRange(for mark: ReviewMark, in text: String) -> Range<String.Index>? {
        anchorRange(quote: mark.quote ?? "", prefix: mark.prefix ?? "",
                    start: mark.start ?? 0, in: text)
    }

    /// The anchor as an `NSRange` (UTF-16) for text-view highlighting.
    static func anchorNSRange(for mark: ReviewMark, in text: String) -> NSRange? {
        guard let r = anchorRange(for: mark, in: text) else { return nil }
        return NSRange(r, in: text)
    }

    // MARK: Suggest application (pure)

    /// Applies a `suggest` mark to `content` by replacing the anchored `quote`
    /// with `replacement`. Returns the new content, or nil when the anchor is
    /// gone (caller marks the suggestion `needs-rebase` and leaves the file).
    static func applySuggest(_ mark: ReviewMark, to content: String) -> String? {
        guard mark.isSuggestion, let replacement = mark.replacement,
              let r = anchorRange(for: mark, in: content) else { return nil }
        return content.replacingCharacters(in: r, with: replacement)
    }
}

// MARK: - Anchor capture (creating a mark from a selection)

extension ReviewSidecar {
    /// Builds the anchor fields for a fresh mark from a selected range in the
    /// raw text: quote = the selection, prefix = up to 30 UTF-16 units before
    /// it (smotr's window), start = the UTF-16 offset — smotr's web view
    /// reads these as JS string indices, so grapheme counts would drift on
    /// any document containing emoji or combining marks.
    static func captureAnchor(in text: String, range: Range<String.Index>)
        -> (quote: String, prefix: String, start: Int) {
        let quote = String(text[range])
        let ns = text as NSString
        let start = NSRange(range, in: text).location
        var prefixStart = max(0, start - 30)
        // Never split a surrogate pair at the window edge.
        if prefixStart > 0, UTF16.isTrailSurrogate(ns.character(at: prefixStart)) {
            prefixStart -= 1
        }
        let prefix = ns.substring(
            with: NSRange(location: prefixStart, length: start - prefixStart))
        return (quote, prefix, start)
    }
}
