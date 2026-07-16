import Foundation

/// Line-ending style of a document buffer (not of a specific disk file).
enum LineEndingKind: String, Equatable, Sendable {
    case lf
    case crlf
    /// Classic Mac bare CR only (rare).
    case cr
    case mixed
    /// Empty text or a single line with no terminators.
    case none
}

/// Document-level statistics for the inspector Info tab. Pure function of the
/// markdown string — no disk I/O, safe to call off-main and to unit-test.
struct FileInfoStats: Equatable, Sendable {
    var words: Int
    var chars: Int
    var lines: Int
    var headings: Int
    var lineEndings: LineEndingKind
    var hasTrailingNewline: Bool
}

/// Word / character / line / heading / line-ending stats for `text`.
/// Words and chars reuse `wordAndCharCount` (status bar). Headings use
/// `markdownOutline` so fence-hidden `#` lines are not counted.
func computeFileInfoStats(text: String) -> FileInfoStats {
    let (words, chars) = wordAndCharCount(in: text)
    let lineEndings = detectLineEndings(in: text)
    let hasTrailingNewline = textHasTrailingNewline(text)
    let lines = lineCount(in: text)
    let headings = markdownOutline(text).count
    return FileInfoStats(
        words: words,
        chars: chars,
        lines: lines,
        headings: headings,
        lineEndings: lineEndings,
        hasTrailingNewline: hasTrailingNewline
    )
}

/// Number of lines as a text editor would show them: empty string → 0;
/// `"a"` → 1; `"a\n"` → 1 (trailing newline does not open an empty last line
/// for the count — matches `split(separator: "\n", omittingEmptySubsequences: false)`
/// only when there is no trailing terminator, otherwise `components` of `\n`
/// with a drop of the final empty fragment).
/// Walk Unicode scalars — Swift `Character` treats CRLF (`\r\n`) as one
/// extended grapheme cluster, which would hide CRLF vs LF detection.
func lineCount(in text: String) -> Int {
    if text.isEmpty { return 0 }
    var count = 1
    let scalars = text.unicodeScalars
    var i = scalars.startIndex
    while i < scalars.endIndex {
        let s = scalars[i]
        if s == "\r" {
            var next = scalars.index(after: i)
            if next < scalars.endIndex, scalars[next] == "\n" {
                next = scalars.index(after: next)
            }
            // Trailing terminator does not open an extra empty line.
            if next < scalars.endIndex { count += 1 }
            i = next
        } else if s == "\n" {
            let next = scalars.index(after: i)
            if next < scalars.endIndex { count += 1 }
            i = next
        } else {
            i = scalars.index(after: i)
        }
    }
    return count
}

func textHasTrailingNewline(_ text: String) -> Bool {
    guard let last = text.unicodeScalars.last else { return false }
    return last == "\n" || last == "\r"
}

func detectLineEndings(in text: String) -> LineEndingKind {
    var sawLF = false
    var sawCRLF = false
    var sawCR = false
    let scalars = text.unicodeScalars
    var i = scalars.startIndex
    while i < scalars.endIndex {
        let s = scalars[i]
        if s == "\r" {
            let next = scalars.index(after: i)
            if next < scalars.endIndex, scalars[next] == "\n" {
                sawCRLF = true
                i = scalars.index(after: next)
                continue
            }
            // Bare CR is distinct from LF and CRLF (classic Mac).
            sawCR = true
            i = next
            continue
        }
        if s == "\n" {
            sawLF = true
        }
        i = scalars.index(after: i)
    }
    let kinds = [sawLF, sawCRLF, sawCR].filter(\.self).count
    if kinds == 0 { return .none }
    if kinds > 1 { return .mixed }
    if sawLF { return .lf }
    if sawCRLF { return .crlf }
    return .cr
}

/// Convert every line terminator to LF and ensure the document ends with one.
/// Returns nil when the buffer already satisfies both conditions.
func normalizeLineEndings(text: String) -> String? {
    var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
    if !normalized.hasSuffix("\n") {
        normalized.append("\n")
    }
    return normalized == text ? nil : normalized
}

// MARK: - Disk metadata (off-main)

/// Lightweight file attributes for the Info tab. Fetched off-main via
/// `resourceValues`; never from SwiftUI `body`.
struct FileDiskInfo: Equatable, Sendable {
    var byteSize: Int64?
    var modificationDate: Date?

    static let empty = FileDiskInfo(byteSize: nil, modificationDate: nil)
}

/// Read size + mtime for `url`. Call from a detached / background task.
func loadFileDiskInfo(for url: URL) -> FileDiskInfo {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let size: Int64?
    if let s = values?.fileSize {
        size = Int64(s)
    } else {
        size = nil
    }
    return FileDiskInfo(byteSize: size, modificationDate: values?.contentModificationDate)
}

/// Human-readable byte size (B / KB / MB).
func formatByteSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let kb = Double(bytes) / 1024.0
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    let mb = kb / 1024.0
    return String(format: "%.1f MB", mb)
}

/// Caption for `LineEndingKind` in the Info panel.
func lineEndingCaption(_ kind: LineEndingKind) -> String {
    switch kind {
    case .lf: return "LF"
    case .crlf: return "CRLF"
    case .cr: return "CR"
    case .mixed: return "Mixed"
    case .none: return "—"
    }
}
