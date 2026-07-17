import AppKit

// Pure Visual-mode editing helpers (unit-tested), extracted from
// VisualTextView.swift.

/// Visual uses its semantic Markdown/table door first; image is a fallback.
/// The URL door comes last (before plain text): it only fires for a pure-URL
/// clipboard over a non-empty selection. The individual doors share the same
/// semantic context predicate below.
func handleVisualSpecialPaste(pasteMarkdown: () -> Bool,
                              pasteImage: () -> Bool,
                              pasteURLLink: () -> Bool) -> Bool {
    if pasteMarkdown() { return true }
    if pasteImage() { return true }
    return pasteURLLink()
}

// MARK: - Pure editing helpers (unit-tested)

/// Autoformat trigger: paragraph text prefix → block kind + consumed chars.
/// `currentKind` supplies list depth context ("[] " inside a bullet keeps depth).
func autoformatKind(for text: String, currentKind: MDBlock.Kind) -> (kind: MDBlock.Kind, consumed: Int)? {
    let depth: Int
    switch currentKind {
    case .bulletItem(let d), .orderedItem(let d, _), .taskItem(let d, _),
         .builtInPluginTaskItem(let d, _):
        depth = d
    case .paragraph:
        depth = 0
    default:
        return nil  // headings/code/raw don't autoformat
    }

    if text.hasPrefix("[] ") || text.hasPrefix("[ ] ") {
        return (.taskItem(depth: depth, done: false), text.hasPrefix("[] ") ? 3 : 4)
    }
    if text.hasPrefix("[x] ") {
        return (.taskItem(depth: depth, done: true), 4)
    }

    // The remaining triggers only convert plain paragraphs.
    guard case .paragraph = currentKind else { return nil }

    if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") {
        return (.bulletItem(depth: 0), 2)
    }
    let hashes = text.prefix(while: { $0 == "#" })
    if (1...6).contains(hashes.count),
       text.dropFirst(hashes.count).first == " " {
        return (.heading(hashes.count), hashes.count + 1)
    }
    let digits = text.prefix(while: { $0.isNumber })
    if !digits.isEmpty, digits.count <= 9,
       let number = Int(digits),
       text.dropFirst(digits.count).hasPrefix(". ") {
        return (.orderedItem(depth: 0, number: number), digits.count + 2)
    }
    return nil
}

/// Block kind for the next paragraph after pressing Enter at the end of `kind`.
/// nil → plain paragraph.
func continuationKind(after kind: MDBlock.Kind) -> MDBlock.Kind? {
    switch kind {
    case .bulletItem(let depth):
        return .bulletItem(depth: depth)
    case .orderedItem(let depth, let number):
        return .orderedItem(depth: depth, number: number + 1)
    case .taskItem(let depth, _):
        return .taskItem(depth: depth, done: false)
    case .builtInPluginTaskItem(let depth, let token):
        return .builtInPluginTaskItem(
            depth: depth,
            token: BuiltInPluginTokenPayload(pluginID: token.pluginID, states: token.states,
                                             stateIndex: 0))
    case .listContinuation(let indent):
        return .listContinuation(indent: indent)
    case .codeBlock:
        return kind
    default:
        return nil
    }
}

/// Tab navigation order inside a table; nil = past the edge (forward: caller
/// appends a row; backward: stay put).
func nextTableCellPosition(row: Int, column: Int, columns: Int, rows: Int,
                           forward: Bool) -> (row: Int, column: Int)? {
    if forward {
        if column + 1 < columns { return (row, column + 1) }
        if row + 1 < rows { return (row + 1, 0) }
        return nil
    }
    if column > 0 { return (row, column - 1) }
    if row > 0 { return (row - 1, columns - 1) }
    return nil
}

/// Kind after Tab / Shift+Tab on a list item; nil when not applicable.
func indentedKind(_ kind: MDBlock.Kind, by delta: Int) -> MDBlock.Kind? {
    func clamp(_ d: Int) -> Int? {
        let next = d + delta
        return next >= 0 && next <= 5 ? next : nil
    }
    switch kind {
    case .bulletItem(let d):
        return clamp(d).map { .bulletItem(depth: $0) }
    case .orderedItem(let d, let n):
        return clamp(d).map { .orderedItem(depth: $0, number: n) }
    case .taskItem(let d, let done):
        return clamp(d).map { .taskItem(depth: $0, done: done) }
    case .builtInPluginTaskItem(let d, let token):
        return clamp(d).map { .builtInPluginTaskItem(depth: $0, token: token) }
    default:
        return nil
    }
}

func isChecklistKind(_ kind: MDBlock.Kind) -> Bool {
    switch kind {
    case .taskItem, .builtInPluginTaskItem:
        return true
    default:
        return false
    }
}

func allBlocksAreChecklists(_ blocks: [MDBlock]) -> Bool {
    !blocks.isEmpty && blocks.allSatisfy { isChecklistKind($0.kind) }
}

func builtInPluginFrontmatterSource(in markdown: String) -> String? {
    guard let range = frontmatterRange(in: markdown)?.full else { return nil }
    return (markdown as NSString).substring(with: range)
}

@discardableResult
func refreshBuiltInPluginSnapshot(
    for markdown: String,
    cachedFrontmatter: inout String?,
    snapshot: inout BuiltInPluginSnapshot
) -> Bool {
    let currentFrontmatter = builtInPluginFrontmatterSource(in: markdown)
    guard currentFrontmatter != cachedFrontmatter else { return false }
    cachedFrontmatter = currentFrontmatter
    snapshot = BuiltInPluginRegistry.snapshot(for: markdown)
    return true
}

func checklistKind(depth: Int,
                   initialPluginPayload: BuiltInPluginTokenPayload?) -> MDBlock.Kind {
    if let initialPluginPayload {
        return .builtInPluginTaskItem(depth: depth, token: initialPluginPayload)
    }
    return .taskItem(depth: depth, done: false)
}

/// Conservative clipboard heuristic: format text only when it carries
/// unambiguous Markdown structure. Ordinary prose (including punctuation and
/// underscores in identifiers) must keep the normal plain-text paste path.
/// Compiled once — paste re-ran 12 NSRegularExpression inits per call before.
private let visualPasteMarkdownRegexes: [NSRegularExpression] = [
    #"(?m)^\s{0,3}#{1,6}\s+\S"#,             // heading
    #"(?m)^\s{0,3}(?:[-+*]|\d+[.)])\s+\S"#, // list
    #"(?m)^\s{0,3}>\s?\S"#,                 // quote
    #"(?m)^\s*```[^\n]*$"#,                 // fenced code
    #"(?m)^\s*(?:---+|\*\*\*+)\s*$"#,      // thematic break
    #"(?m)^\s*\|?.+\|.+\n\s*\|?\s*:?-{3}"#, // table
    #"!\[[^\]\n]*\]\([^\)\n]+\)"#,        // image
    #"\[[^\]\n]+\]\([^\)\n]+\)"#,         // link
    #"\[\[[^\]\n]+\]\]"#,                 // wiki-link
    #"(?:\*\*|~~|==)[^\n]+?(?:\*\*|~~|==)"#,
    #"(?<!\*)\*[^*\n]+\*(?!\*)"#,          // emphasis
    #"`[^`\n]+`"#,                           // inline code
].compactMap { try? NSRegularExpression(pattern: $0) }

func looksLikeMarkdownForVisualPaste(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    let full = NSRange(location: 0, length: (text as NSString).length)
    return visualPasteMarkdownRegexes.contains {
        $0.firstMatch(in: text, range: full) != nil
    }
}

/// Code blocks are literal by definition: Markdown-looking clipboard text
/// pasted there must keep every marker instead of being rendered.
func shouldFormatVisualPaste(_ text: String, in blockKind: MDBlock.Kind) -> Bool {
    visualContextAllowsStructuredPaste(blockKind) && looksLikeMarkdownForVisualPaste(text)
}

/// Literal and structurally constrained Visual blocks must use NSTextView's
/// plain-text paste. Shared by Markdown/table and image doors.
func visualContextAllowsStructuredPaste(_ kind: MDBlock.Kind) -> Bool {
    switch kind {
    case .codeBlock, .tableCell, .raw: return false
    default: return true
    }
}
