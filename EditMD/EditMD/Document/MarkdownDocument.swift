import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdown = UTType("net.daringfireball.markdown")!
    static let textBundle = UTType("org.textbundle.package")!
}

/// True when a document is large or table-heavy enough that the Visual mode's
/// NSTextTable layout would peg the CPU (a 9000-cell table hangs indefinitely),
/// or the per-keystroke work would lag. Such documents open in plain Source
/// (no syntax highlighting, no lint) instead. Cheap single pass with early-out.
///
/// The trigger is deliberately table-aware, not size-only: a large prose note
/// lays out fine in Visual, whereas even a modest document that is mostly one
/// GFM table does not (the layout cost is super-linear in cell count).
func markdownIsHeavy(_ content: String) -> Bool {
    let length = content.utf16.count
    if length > 200_000 { return true }   // extreme size — plain regardless
    if length < 40_000 { return false }   // comfortably small
    // In between: heavy only when table-dominated (the NSTextTable trap).
    var rows = 0
    var atLineStart = true
    for ch in content {
        if ch == "\n" { atLineStart = true; continue }
        guard atLineStart else { continue }
        if ch == " " || ch == "\t" { continue }   // skip leading indent
        atLineStart = false
        if ch == "|" {
            rows += 1
            if rows > 300 { return true }
        }
    }
    return false
}

final class MarkdownDocument: ReferenceFileDocument {

    // nonisolated(unsafe) because ReferenceFileDocument protocol methods are nonisolated.
    // didSet publishes the change so SwiftUI-only readers (the outline sidebar,
    // the split's live preview, the Preview status bar) refresh on every edit —
    // editors write from the main thread, and init assignments skip didSet.
    nonisolated(unsafe) var content: String {
        didSet {
            guard content != oldValue else { return }
            isHeavy = markdownIsHeavy(content)
            objectWillChange.send()
        }
    }
    nonisolated(unsafe) var assetsFileWrapper: FileWrapper?

    /// Large/table-heavy documents skip the per-keystroke syntax highlighting
    /// and lint in Source (they would freeze on a 300K single-table file). See
    /// `markdownIsHeavy`. Recomputed cheaply whenever `content` changes.
    nonisolated(unsafe) private(set) var isHeavy = false

    struct Snapshot: @unchecked Sendable {
        let content: String
        let assetsFileWrapper: FileWrapper?
    }

    static var readableContentTypes: [UTType] { [.markdown, .textBundle] }
    static var writableContentTypes: [UTType] { [.markdown, .textBundle] }

    // MARK: - Init

    init() {
        content = ""
        assetsFileWrapper = nil
    }

    init(configuration: ReadConfiguration) throws {
        let (text, assets) = try parseMarkdownWrapper(
            configuration.file,
            isTextBundle: configuration.contentType == .textBundle)
        content = text
        assetsFileWrapper = assets
        isHeavy = markdownIsHeavy(text)
    }

    // MARK: - Snapshot & Write

    func snapshot(contentType: UTType) throws -> Snapshot {
        Snapshot(content: content, assetsFileWrapper: assetsFileWrapper)
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        makeMarkdownWrapper(content: snapshot.content,
                            assets: snapshot.assetsFileWrapper,
                            isTextBundle: configuration.contentType == .textBundle)
    }
}
