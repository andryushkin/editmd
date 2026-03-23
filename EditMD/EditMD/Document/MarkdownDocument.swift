import AppKit

private struct TextBundleInfo: Encodable {
    var version: Int = 2
    var type: String = "net.daringfireball.markdown"
    var creatorIdentifier: String?
}

final class MarkdownDocument: NSDocument {

    // nonisolated(unsafe) because read methods are called on a background thread by NSDocument
    nonisolated(unsafe) var content: String = ""
    nonisolated(unsafe) var assetsFileWrapper: FileWrapper? = nil

    // MARK: - NSDocument

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let wc = EditorWindowController(document: self)
        addWindowController(wc)
    }

    // MARK: - Flat file (.md / .markdown)

    override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        content = text
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let data = content.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }

    // MARK: - Package (.textbundle)

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard let wrappers = fileWrapper.fileWrappers,
              let textWrapper = wrappers.first(where: { $0.key.hasPrefix("text.") })?.value,
              let data = textWrapper.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        content = text
        assetsFileWrapper = wrappers["assets"]
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        guard typeName == "org.textbundle.package" else {
            return try super.fileWrapper(ofType: typeName)
        }

        let root = FileWrapper(directoryWithFileWrappers: [:])

        let infoData = try JSONEncoder().encode(TextBundleInfo(creatorIdentifier: Bundle.main.bundleIdentifier))
        let infoWrapper = FileWrapper(regularFileWithContents: infoData)
        infoWrapper.preferredFilename = "info.json"
        root.addFileWrapper(infoWrapper)

        let textData = content.data(using: .utf8) ?? Data()
        let textWrapper = FileWrapper(regularFileWithContents: textData)
        textWrapper.preferredFilename = "text.md"
        root.addFileWrapper(textWrapper)

        if let assets = assetsFileWrapper {
            assets.preferredFilename = "assets"
            root.addFileWrapper(assets)
        }

        return root
    }
}
