import Foundation
import Markdown

/// One heading in the document outline (the sidebar): level 1–6, the plain
/// rendered title (inline markup stripped), and the UTF-16 offset of the
/// heading's first character in the markdown source — the jump target for
/// EditorPositionStore.requestJump.
struct OutlineItem: Equatable, Identifiable {
    let level: Int
    let title: String
    let markdownOffset: Int

    /// Offsets are unique per heading (two headings can't start at the same
    /// source position), so the offset doubles as a stable identity.
    var id: Int { markdownOffset }
}

/// Extracts the heading outline from markdown text. Pure function of the
/// text: parses with swift-markdown (so `# text` inside code fences is never
/// a heading), positions convert through LineIndex (source columns are
/// 1-based UTF-8 bytes, see the cmark notes in CLAUDE.md).
func markdownOutline(_ text: String) -> [OutlineItem] {
    guard !text.isEmpty else { return [] }
    let document = Document(parsing: text)
    var collector = OutlineCollector(lineIdx: LineIndex(text))
    collector.visit(document)
    return collector.items
}

private struct OutlineCollector: MarkupWalker {
    let lineIdx: LineIndex
    var items: [OutlineItem] = []

    mutating func visitHeading(_ heading: Heading) {
        guard let src = heading.range else { return }
        // Headings contain only inline children — no descendInto needed;
        // headings nested in blockquotes/lists are reached by defaultVisit.
        items.append(OutlineItem(
            level: heading.level,
            title: heading.plainText,
            markdownOffset: lineIdx.offset(src.lowerBound.line, src.lowerBound.column)
        ))
    }
}
