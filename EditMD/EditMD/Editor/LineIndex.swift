import Foundation

// MARK: - Line Index

/// Maps swift-markdown's 1-based (line, UTF-8 column) positions to UTF-16 NSRange offsets.
struct LineIndex {
    /// utf8To16[byteOffset] = UTF-16 unit offset at the start of that byte.
    private let utf8To16: [Int]
    /// 0-indexed: entry n = UTF-8 byte start of line n+1.
    private let lineU8: [Int]
    /// 0-indexed: entry n = UTF-16 offset start of line n+1.
    private let lineU16: [Int]

    init(_ string: String) {
        var u8 = [0], u16 = [0]
        var map = [Int]()
        map.reserveCapacity(string.utf8.count + 1)
        var c16 = 0
        for scalar in string.unicodeScalars {
            let nb = scalar.utf8.count
            for _ in 0..<nb { map.append(c16) }
            c16 += scalar.utf16.count
            if scalar.value == 0x0A {
                u8.append(map.count)
                u16.append(c16)
            }
        }
        map.append(c16)  // sentinel: one past the end
        self.utf8To16 = map
        self.lineU8 = u8
        self.lineU16 = u16
    }

    var lineCount: Int { lineU8.count }

    /// 1-based line number containing a UTF-16 offset (binary search over
    /// line starts — the link scan calls this per link, it must not be O(n)).
    func lineNumber(utf16Offset: Int) -> Int {
        var lo = 0, hi = lineU16.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineU16[mid] <= utf16Offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// UTF-16 bounds of the line containing `utf16Offset`, excluding the
    /// trailing `\n` (a `\r` of a CRLF ending stays — callers trim it).
    func lineBounds(utf16Offset: Int) -> (start: Int, end: Int) {
        let line = lineNumber(utf16Offset: utf16Offset)
        let start = lineU16[line - 1]
        let end = line < lineU16.count ? lineU16[line] - 1 : (utf8To16.last ?? start)
        return (start, max(start, end))
    }

    /// 1-based line + 1-based UTF-8 byte column → UTF-16 unit offset.
    func offset(_ line: Int, _ col: Int) -> Int {
        guard line >= 1, line <= lineU8.count else { return utf8To16.count - 1 }
        let b = lineU8[line - 1] + col - 1
        return b < utf8To16.count ? utf8To16[b] : utf8To16.last ?? 0
    }

    /// UTF-16 offset AFTER the character at (1-based line, 1-based UTF-8 col).
    func offsetAfter(_ line: Int, _ col: Int) -> Int {
        guard line >= 1, line <= lineU8.count else { return utf8To16.count - 1 }
        let b = lineU8[line - 1] + col - 1
        guard b < utf8To16.count else { return utf8To16.last ?? 0 }
        let v = utf8To16[b]
        var n = b + 1
        while n < utf8To16.count, utf8To16[n] == v { n += 1 }
        return n < utf8To16.count ? utf8To16[n] : utf8To16.last ?? 0
    }

    /// NSRange for cmark node positions (1-based, endCol inclusive).
    func range(_ sl: Int, _ sc: Int, _ el: Int, _ ec: Int) -> NSRange? {
        let loc = offset(sl, sc)
        let end = offsetAfter(el, ec)
        guard end >= loc else { return nil }
        return NSRange(location: loc, length: end - loc)
    }

    /// UTF-16 start offset of a line (1-based line number).
    func lineStart(_ line: Int) -> Int {
        guard line >= 1, line <= lineU16.count else { return utf8To16.count - 1 }
        return lineU16[line - 1]
    }
}
