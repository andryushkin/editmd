import Foundation

// MARK: - Query model

/// Parsed workspace search query. Pure value; no I/O.
struct SearchQuery: Equatable, Sendable {
    /// Free-text AND tokens (case-insensitive match in body or file name).
    var tokens: [String]
    /// Quoted phrases (case-insensitive substring; may span word boundaries).
    var phrases: [String]
    /// `path:` prefix of the relative path (no leading slash required).
    var pathPrefix: String?
    /// `type:md` / `type:*` etc. Default when nil: markdown only at scan time.
    var fileType: SearchFileTypeFilter?
    /// `tag:` values (AND — file must carry every listed tag).
    var tags: [String]
    /// `is:modified` — git porcelain not clean.
    var isModified: Bool
    /// `after:YYYY-MM-DD` — mtime ≥ start of that local calendar day (inclusive).
    var afterDate: Date?
    /// `before:YYYY-MM-DD` — mtime < start of the *next* local day
    /// (i.e. the named day is included through 23:59:59.999).
    var beforeDate: Date?

    /// No tokens, phrases, or active filters.
    var isEmpty: Bool {
        tokens.isEmpty
            && phrases.isEmpty
            && pathPrefix == nil
            && fileType == nil
            && tags.isEmpty
            && !isModified
            && afterDate == nil
            && beforeDate == nil
    }

    /// Has at least one content/name text constraint (token or phrase).
    var hasTextConstraints: Bool {
        !tokens.isEmpty || !phrases.isEmpty
    }

    /// Has any structural filter (path/type/tag/git/dates).
    var hasStructuralFilters: Bool {
        pathPrefix != nil
            || fileType != nil
            || !tags.isEmpty
            || isModified
            || afterDate != nil
            || beforeDate != nil
    }

    static let empty = SearchQuery(
        tokens: [], phrases: [], pathPrefix: nil, fileType: nil,
        tags: [], isModified: false, afterDate: nil, beforeDate: nil
    )
}

/// `type:` filter value.
enum SearchFileTypeFilter: Equatable, Sendable {
    /// Match a single extension (lowercase, no dot), e.g. `md`.
    case fileExtension(String)
    /// `type:*` — all text-like files the scanner admits.
    case allText
}

// MARK: - Parser

/// Known filter keys. Anything else with `key:value` stays a free-text token.
private let knownSearchFilterKeys: Set<String> = [
    "path", "type", "tag", "is", "after", "before"
]

/// Parse a raytsystem-like search string into a `SearchQuery`.
/// Unknown `key:` pairs degrade to ordinary tokens. Unclosed quotes take the
/// remainder of the string as a phrase (soft recovery).
func parseSearchQuery(_ raw: String) -> SearchQuery {
    let pieces = tokenizeSearchQuery(raw)
    var tokens: [String] = []
    var phrases: [String] = []
    var pathPrefix: String?
    var fileType: SearchFileTypeFilter?
    var tags: [String] = []
    var isModified = false
    var afterDate: Date?
    var beforeDate: Date?

    for piece in pieces {
        switch piece {
        case .phrase(let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { phrases.append(t) }

        case .word(let text):
            if let filter = splitSearchFilter(text) {
                let key = filter.key.lowercased()
                let value = filter.value
                if knownSearchFilterKeys.contains(key) {
                    applySearchFilter(
                        key: key, value: value,
                        pathPrefix: &pathPrefix,
                        fileType: &fileType,
                        tags: &tags,
                        isModified: &isModified,
                        afterDate: &afterDate,
                        beforeDate: &beforeDate,
                        tokens: &tokens,
                        rawWord: text
                    )
                } else {
                    // Soft degrade: unknown key keeps the whole word as a token.
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { tokens.append(t) }
                }
            } else {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { tokens.append(t) }
            }
        }
    }

    return SearchQuery(
        tokens: tokens,
        phrases: phrases,
        pathPrefix: pathPrefix,
        fileType: fileType,
        tags: tags,
        isModified: isModified,
        afterDate: afterDate,
        beforeDate: beforeDate
    )
}

// MARK: - Tokenization

enum SearchTokenPiece: Equatable {
    case word(String)
    case phrase(String)
}

/// Split on whitespace; double-quoted spans become phrases.
/// Unclosed `"` → remainder of string is one phrase.
func tokenizeSearchQuery(_ raw: String) -> [SearchTokenPiece] {
    var result: [SearchTokenPiece] = []
    let chars = Array(raw)
    var i = 0
    let n = chars.count

    func skipSpaces() {
        while i < n, chars[i].isWhitespace { i += 1 }
    }

    while i < n {
        skipSpaces()
        guard i < n else { break }

        if chars[i] == "\"" {
            i += 1 // opening quote
            var body: [Character] = []
            var closed = false
            while i < n {
                if chars[i] == "\"" {
                    closed = true
                    i += 1
                    break
                }
                body.append(chars[i])
                i += 1
            }
            // Unclosed: body is everything to end (already consumed).
            _ = closed
            result.append(.phrase(String(body)))
            continue
        }

        // Bare word (may contain key:value or key:"quoted value" after colon).
        // Special case: path:"мои заметки" — key, colon, then quoted value.
        if let filterWithQuoted = tryParseFilterWithQuotedValue(chars, start: i) {
            result.append(.word(filterWithQuoted.token))
            i = filterWithQuoted.nextIndex
            continue
        }

        var word: [Character] = []
        while i < n, !chars[i].isWhitespace {
            // Stop before a free-standing quote that starts a new phrase.
            if chars[i] == "\"" { break }
            word.append(chars[i])
            i += 1
        }
        if !word.isEmpty {
            result.append(.word(String(word)))
        }
    }
    return result
}

/// Parse `key:"value with spaces"` as a single synthetic word `key:value with spaces`
/// so the filter applicator sees an unquoted value with spaces preserved.
private func tryParseFilterWithQuotedValue(
    _ chars: [Character], start: Int
) -> (token: String, nextIndex: Int)? {
    var i = start
    let n = chars.count
    // key
    var key: [Character] = []
    while i < n, chars[i].isLetter || chars[i] == "_" {
        key.append(chars[i])
        i += 1
    }
    guard !key.isEmpty, i < n, chars[i] == ":" else { return nil }
    i += 1
    guard i < n, chars[i] == "\"" else { return nil }
    i += 1 // opening quote of value
    var value: [Character] = []
    while i < n {
        if chars[i] == "\"" {
            i += 1
            break
        }
        value.append(chars[i])
        i += 1
    }
    let token = String(key) + ":" + String(value)
    return (token, i)
}

// MARK: - Filter application

private func splitSearchFilter(_ word: String) -> (key: String, value: String)? {
    guard let colon = word.firstIndex(of: ":") else { return nil }
    let key = String(word[..<colon])
    // Require non-empty key of identifier shape; value may be empty.
    guard !key.isEmpty,
          key.allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
    let valueStart = word.index(after: colon)
    let value = String(word[valueStart...])
    return (key, value)
}

private func applySearchFilter(
    key: String,
    value: String,
    pathPrefix: inout String?,
    fileType: inout SearchFileTypeFilter?,
    tags: inout [String],
    isModified: inout Bool,
    afterDate: inout Date?,
    beforeDate: inout Date?,
    tokens: inout [String],
    rawWord: String
) {
    switch key {
    case "path":
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip optional leading "./" and leading slashes for stable prefix match.
        var p = v
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        while p.hasPrefix("/") { p = String(p.dropFirst()) }
        if !p.isEmpty { pathPrefix = p }

    case "type":
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v == "*" {
            fileType = .allText
        } else if !v.isEmpty {
            // Accept ".md" and "md".
            let ext = v.hasPrefix(".") ? String(v.dropFirst()) : v
            if !ext.isEmpty { fileType = .fileExtension(ext) }
        }

    case "tag":
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { tags.append(v) }

    case "is":
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v == "modified" {
            isModified = true
        } else {
            // Unknown is: value → keep as free token (soft degrade).
            let t = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { tokens.append(t) }
        }

    case "after":
        if let d = parseSearchDate(value) {
            afterDate = d
        } else {
            let t = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { tokens.append(t) }
        }

    case "before":
        if let d = parseSearchDate(value) {
            beforeDate = d
        } else {
            let t = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { tokens.append(t) }
        }

    default:
        break
    }
}

/// Parse `YYYY-MM-DD` as the start of that day in the current calendar/timezone.
func parseSearchDate(_ raw: String) -> Date? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = s.split(separator: "-")
    guard parts.count == 3,
          let y = Int(parts[0]),
          let m = Int(parts[1]),
          let d = Int(parts[2]),
          y >= 1970, m >= 1, m <= 12, d >= 1, d <= 31
    else { return nil }
    var comps = DateComponents()
    comps.year = y
    comps.month = m
    comps.day = d
    comps.hour = 0
    comps.minute = 0
    comps.second = 0
    return Calendar.current.date(from: comps)
}

/// Start of the calendar day after `date` (for inclusive `before:` upper bound).
func searchDateEndExclusive(_ date: Date) -> Date {
    Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
}
