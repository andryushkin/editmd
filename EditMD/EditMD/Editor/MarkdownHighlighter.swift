import Foundation
import cmark_gfm
import cmark_gfm_extensions

// MARK: - Line Index

/// Maps cmark's 1-based (line, UTF-8 column) positions to UTF-16 NSRange offsets.
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

// MARK: - Highlight Span

struct Span {
    enum Kind {
        // Existing
        case headingBody(Int), headingMarker
        case boldBody, boldMarker
        case italicBody, italicMarker
        case code
        case linkText, linkSyntax
        case quoteBody, quoteMarker
        // New
        case codeBlockBody, codeBlockFence
        case thematicBreak
        case listMarker
        case imageText, imageSyntax
        case htmlInline
        case htmlBlock
        case strikethroughBody, strikethroughMarker
        case tableDelimiter
        case tableHeader
    }
    var range: NSRange
    var kind: Kind
}

// MARK: - collectSpans

/// Parses the markdown text with cmark and returns highlight spans.
/// Pure function — no dependency on any view or controller.
func collectSpans(_ text: String) -> [Span] {
    guard !text.isEmpty else { return [] }
    let lineIdx = LineIndex(text)
    let nsText  = text as NSString

    // Use parser API to support GFM extensions (strikethrough, table, tasklist, autolink).
    cmark_gfm_core_extensions_ensure_registered()
    guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return [] }
    defer { cmark_parser_free(parser) }
    for name in ["strikethrough", "table", "tasklist", "autolink"] {
        if let ext = cmark_find_syntax_extension(name) {
            cmark_parser_attach_syntax_extension(parser, ext)
        }
    }
    cmark_parser_feed(parser, text, text.utf8.count)
    guard let doc = cmark_parser_finish(parser) else { return [] }
    defer { cmark_node_free(doc) }

    guard let iter = cmark_iter_new(doc) else { return [] }
    defer { cmark_iter_free(iter) }

    var spans = [Span]()

    while true {
        let ev = cmark_iter_next(iter)
        if ev == CMARK_EVENT_DONE { break }
        if ev != CMARK_EVENT_ENTER { continue }
        guard let node = cmark_iter_get_node(iter) else { continue }

        let sl = Int(cmark_node_get_start_line(node))
        let sc = Int(cmark_node_get_start_column(node))
        let el = Int(cmark_node_get_end_line(node))
        let ec = Int(cmark_node_get_end_column(node))
        let nt = cmark_node_get_type(node)

        // Extension node types are extern variables, not accessible from Swift module.
        // Compare by type string for extension nodes.
        let typeStr: String? = {
            guard let ptr = cmark_node_get_type_string(node) else { return nil }
            return String(cString: ptr)
        }()

        if nt == CMARK_NODE_HEADING {
            guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
            let lv = Int(cmark_node_get_heading_level(node))
            spans.append(Span(range: r, kind: .headingBody(lv)))
            // Marker = the '#' characters + one space (level + 1 chars)
            let markerLen = min(lv + 1, r.length)
            spans.append(Span(range: NSRange(location: r.location, length: markerLen), kind: .headingMarker))

        } else if nt == CMARK_NODE_STRONG {
            guard let r = lineIdx.range(sl, sc, el, ec), r.length >= 4 else { continue }
            spans.append(Span(range: r, kind: .boldBody))
            spans.append(Span(range: NSRange(location: r.location, length: 2),             kind: .boldMarker))
            spans.append(Span(range: NSRange(location: r.upperBound - 2, length: 2),       kind: .boldMarker))

        } else if nt == CMARK_NODE_EMPH {
            guard let r = lineIdx.range(sl, sc, el, ec), r.length >= 2 else { continue }
            spans.append(Span(range: r, kind: .italicBody))
            spans.append(Span(range: NSRange(location: r.location, length: 1),             kind: .italicMarker))
            spans.append(Span(range: NSRange(location: r.upperBound - 1, length: 1),       kind: .italicMarker))

        } else if nt == CMARK_NODE_CODE {
            // cmark positions for CMARK_NODE_CODE span only the content (no backticks).
            // Expand the range to include opening and closing backticks.
            let bt = Int(cmark_node_get_backtick_count(node))
            guard sc > bt else { continue }
            let fullLoc = lineIdx.offset(sl, sc - bt)
            // Content end (exclusive) + bt closing backticks (ASCII = 1 UTF-16 each)
            let fullEnd = lineIdx.offsetAfter(el, ec) + bt
            guard fullEnd > fullLoc else { continue }
            spans.append(Span(range: NSRange(location: fullLoc, length: fullEnd - fullLoc), kind: .code))

        } else if nt == CMARK_NODE_LINK {
            guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
            let fc = cmark_node_first_child(node)
            let lc = cmark_node_last_child(node)
            if let fc, let lc,
               let textRange = lineIdx.range(
                   Int(cmark_node_get_start_line(fc)), Int(cmark_node_get_start_column(fc)),
                   Int(cmark_node_get_end_line(lc)),   Int(cmark_node_get_end_column(lc))) {
                spans.append(Span(range: textRange, kind: .linkText))
                let beforeLen = textRange.location - r.location
                if beforeLen > 0 {
                    spans.append(Span(range: NSRange(location: r.location, length: beforeLen), kind: .linkSyntax))
                }
                let afterLen = r.upperBound - textRange.upperBound
                if afterLen > 0 {
                    spans.append(Span(range: NSRange(location: textRange.upperBound, length: afterLen), kind: .linkSyntax))
                }
            } else {
                spans.append(Span(range: r, kind: .linkSyntax))
            }

        } else if nt == CMARK_NODE_BLOCK_QUOTE {
            guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
            spans.append(Span(range: r, kind: .quoteBody))
            // Emit a marker for the '>' at column sc on each line of this blockquote.
            // Using offset(line, sc) correctly handles nested quotes where sc > 1.
            for line in sl...el {
                let markerLoc = lineIdx.offset(line, sc)
                guard markerLoc < r.upperBound, markerLoc < nsText.length else { continue }
                if nsText.substring(with: NSRange(location: markerLoc, length: 1)) == ">" {
                    let mLen = min(2, r.upperBound - markerLoc)
                    spans.append(Span(range: NSRange(location: markerLoc, length: mLen), kind: .quoteMarker))
                }
            }

        } else if nt == CMARK_NODE_CODE_BLOCK {
            guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
            spans.append(Span(range: r, kind: .codeBlockBody))

            // Fenced code blocks have fence_info (may be empty string).
            // Indented code blocks return nil for fence_info but also have fence_length == 0.
            let fenceLen = Int(cmark_node_get_fence_info(node) != nil ? 1 : 0)
            if fenceLen > 0 {
                // Opening fence: from block start to end of first line
                if sl < lineIdx.lineCount {
                    let nextLineStart = lineIdx.lineStart(sl + 1)
                    let openLen = nextLineStart - r.location
                    if openLen > 0 {
                        spans.append(Span(range: NSRange(location: r.location, length: openLen),
                                          kind: .codeBlockFence))
                    }
                }
                // Closing fence: last line of the block
                if el > sl {
                    let closeStart = lineIdx.lineStart(el)
                    let closeLen = r.upperBound - closeStart
                    if closeLen > 0, closeStart >= r.location {
                        spans.append(Span(range: NSRange(location: closeStart, length: closeLen),
                                          kind: .codeBlockFence))
                    }
                }
            }

        } else if nt == CMARK_NODE_THEMATIC_BREAK {
            guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
            spans.append(Span(range: r, kind: .thematicBreak))

        } else if nt == CMARK_NODE_ITEM {
            // Extract list marker (bullet or number+delimiter).
            let markerStart = lineIdx.offset(sl, sc)
            guard markerStart < nsText.length else { continue }
            let parent = cmark_node_parent(node)
            let listType = parent != nil ? cmark_node_get_list_type(parent) : CMARK_NO_LIST

            var markerLen = 2  // default: "- " or "* "
            if listType == CMARK_ORDERED_LIST {
                // Scan: digits, then delimiter (. or )), then space
                let maxScan = min(10, nsText.length - markerStart)
                var i = 0
                while i < maxScan {
                    let ch = nsText.character(at: markerStart + i)
                    guard ch >= 0x30, ch <= 0x39 else { break }  // '0'-'9'
                    i += 1
                }
                if i < maxScan { i += 1 }  // delimiter (. or ))
                if i < maxScan { i += 1 }  // space
                markerLen = i
            }
            if markerLen > 0, markerStart + markerLen <= nsText.length {
                spans.append(Span(range: NSRange(location: markerStart, length: markerLen),
                                  kind: .listMarker))
            }

        } else if nt == CMARK_NODE_IMAGE {
            guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
            let fc = cmark_node_first_child(node)
            let lc = cmark_node_last_child(node)
            if let fc, let lc,
               let textRange = lineIdx.range(
                   Int(cmark_node_get_start_line(fc)), Int(cmark_node_get_start_column(fc)),
                   Int(cmark_node_get_end_line(lc)),   Int(cmark_node_get_end_column(lc))) {
                spans.append(Span(range: textRange, kind: .imageText))
                let beforeLen = textRange.location - r.location
                if beforeLen > 0 {
                    spans.append(Span(range: NSRange(location: r.location, length: beforeLen), kind: .imageSyntax))
                }
                let afterLen = r.upperBound - textRange.upperBound
                if afterLen > 0 {
                    spans.append(Span(range: NSRange(location: textRange.upperBound, length: afterLen), kind: .imageSyntax))
                }
            } else {
                spans.append(Span(range: r, kind: .imageSyntax))
            }

        } else if nt == CMARK_NODE_HTML_INLINE {
            guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
            spans.append(Span(range: r, kind: .htmlInline))

        } else if nt == CMARK_NODE_HTML_BLOCK {
            guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
            spans.append(Span(range: r, kind: .htmlBlock))

        } else if typeStr == "strikethrough" {
            guard let r = lineIdx.range(sl, sc, el, ec), r.length >= 4 else { continue }
            spans.append(Span(range: r, kind: .strikethroughBody))
            spans.append(Span(range: NSRange(location: r.location, length: 2),             kind: .strikethroughMarker))
            spans.append(Span(range: NSRange(location: r.upperBound - 2, length: 2),       kind: .strikethroughMarker))

        } else if typeStr == "table" {
            guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
            // Header row: first line
            let headerEnd = sl < lineIdx.lineCount ? lineIdx.lineStart(sl + 1) : r.upperBound
            let headerLen = min(headerEnd - r.location, r.length)
            if headerLen > 0 {
                spans.append(Span(range: NSRange(location: r.location, length: headerLen),
                                  kind: .tableHeader))
            }
            // Find all '|' delimiters in the table range
            for i in r.location..<r.upperBound {
                guard i < nsText.length else { break }
                if nsText.character(at: i) == 0x7C {  // '|'
                    spans.append(Span(range: NSRange(location: i, length: 1),
                                      kind: .tableDelimiter))
                }
            }
        }
    }

    return spans
}
