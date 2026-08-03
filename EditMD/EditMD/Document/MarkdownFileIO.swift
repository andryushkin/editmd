import Foundation
import AppKit

// Serialization + IO for markdown / textbundle files. `MarkdownDocument` and
// `DocumentRegistry` share this ONE read/write format — they must never diverge.

// MARK: - textbundle info.json

private struct TextBundleInfo: Encodable {
    var version: Int = 2
    var type: String = "net.daringfireball.markdown"
    var creatorIdentifier: String?
}

// MARK: - Serialization core (FileWrapper ⇄ content)

/// File wrapper → `(content, assets)`. Mirrors
/// `MarkdownDocument.init(configuration:)`; the single home of the read format.
func parseMarkdownWrapper(_ file: FileWrapper, isTextBundle: Bool) throws -> (content: String, assets: FileWrapper?) {
    if isTextBundle {
        guard let wrappers = file.fileWrappers,
              let textWrapper = wrappers.first(where: { $0.key.hasPrefix("text.") })?.value,
              let data = textWrapper.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        return (text, wrappers["assets"])
    } else {
        guard let data = file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return (text, nil)
    }
}

/// Wrapper to persist. Mirrors
/// `MarkdownDocument.fileWrapper(snapshot:configuration:)`; the single home of
/// the write format.
func makeMarkdownWrapper(content: String, assets: FileWrapper?, isTextBundle: Bool) -> FileWrapper {
    guard isTextBundle else {
        return FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
    }
    let root = FileWrapper(directoryWithFileWrappers: [:])

    let infoData = (try? JSONEncoder().encode(
        TextBundleInfo(creatorIdentifier: Bundle.main.bundleIdentifier))) ?? Data()
    let infoWrapper = FileWrapper(regularFileWithContents: infoData)
    infoWrapper.preferredFilename = "info.json"
    root.addFileWrapper(infoWrapper)

    let textWrapper = FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
    textWrapper.preferredFilename = "text.md"
    root.addFileWrapper(textWrapper)

    if let assets {
        assets.preferredFilename = "assets"
        root.addFileWrapper(assets)
    }
    return root
}

// MARK: - Disk IO

/// Reads `.md`/`.markdown` or a `.textbundle` package (detected by extension
/// or directory shape). Plain files use `String(contentsOf:)` —
/// `FileWrapper(.immediate)` walks xattrs/resource forks and is far too
/// expensive on the hot disk-watch path (froze main on large notes).
func loadMarkdownDocument(from url: URL) throws -> (content: String, assets: FileWrapper?) {
    let ext = url.pathExtension.lowercased()
    if ext == "textbundle" {
        let wrapper = try FileWrapper(url: url, options: .immediate)
        return try parseMarkdownWrapper(wrapper, isTextBundle: true)
    }
    // Regular file (anything not a package): cheap UTF-8 read.
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
        let text = try String(contentsOf: url, encoding: .utf8)
        return (text, nil)
    }
    // Directory-shaped / odd cases still go through FileWrapper.
    let wrapper = try FileWrapper(url: url, options: .immediate)
    return try parseMarkdownWrapper(wrapper, isTextBundle: wrapper.isDirectory)
}

/// Atomic write of content (+ optional textbundle assets). For an existing
/// file the original URL is passed so unchanged sub-wrappers (assets) are
/// reused, not rewritten.
func writeMarkdownDocument(content: String, assets: FileWrapper?, to url: URL) throws {
    let isBundle = url.pathExtension.lowercased() == "textbundle"
    let wrapper = makeMarkdownWrapper(content: content, assets: assets, isTextBundle: isBundle)
    let original = FileManager.default.fileExists(atPath: url.path) ? url : nil
    try wrapper.write(to: url, options: .atomic, originalContentsURL: original)
}

/// Exact value-typed baseline of a textbundle's assets tree. Top-level names
/// alone miss an external rewrite of `assets/image.png`; comparing disk
/// wrappers with the live model confuses a local image insertion with an
/// external conflict. The flattened tree keeps both distinct and survives
/// path/cache transitions.
struct DocumentAssetsFingerprint: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let path: String
        let kind: UInt8
        let payload: Data?
    }

    private let entries: [Entry]

    init(_ root: FileWrapper?) {
        var result: [Entry] = []

        func append(_ wrapper: FileWrapper, path: String) {
            if wrapper.isRegularFile {
                result.append(Entry(
                    path: path,
                    kind: 0,
                    payload: wrapper.regularFileContents))
                return
            }
            if wrapper.isDirectory {
                result.append(Entry(path: path, kind: 1, payload: nil))
                for (name, child) in (wrapper.fileWrappers ?? [:])
                    .sorted(by: { $0.key < $1.key }) {
                    let childPath = path.isEmpty ? name : path + "/" + name
                    append(child, path: childPath)
                }
                return
            }
            if wrapper.isSymbolicLink {
                let destination = wrapper.symbolicLinkDestinationURL?.path ?? ""
                result.append(Entry(
                    path: path,
                    kind: 2,
                    payload: Data(destination.utf8)))
                return
            }
            result.append(Entry(path: path, kind: 3, payload: nil))
        }

        if let root { append(root, path: "") }
        entries = result
    }
}
