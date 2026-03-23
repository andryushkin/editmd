import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdown = UTType("net.daringfireball.markdown")!
    static let textBundle = UTType("org.textbundle.package")!
}

private struct TextBundleInfo: Encodable {
    var version: Int = 2
    var type: String = "net.daringfireball.markdown"
    var creatorIdentifier: String?
}

final class MarkdownDocument: ReferenceFileDocument {

    // nonisolated(unsafe) because ReferenceFileDocument protocol methods are nonisolated
    nonisolated(unsafe) var content: String
    nonisolated(unsafe) var assetsFileWrapper: FileWrapper?

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
        if configuration.contentType == .textBundle {
            guard let wrappers = configuration.file.fileWrappers,
                  let textWrapper = wrappers.first(where: { $0.key.hasPrefix("text.") })?.value,
                  let data = textWrapper.regularFileContents,
                  let text = String(data: data, encoding: .utf8)
            else { throw CocoaError(.fileReadCorruptFile) }
            content = text
            assetsFileWrapper = wrappers["assets"]
        } else {
            guard let data = configuration.file.regularFileContents,
                  let text = String(data: data, encoding: .utf8)
            else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            content = text
            assetsFileWrapper = nil
        }
    }

    // MARK: - Snapshot & Write

    func snapshot(contentType: UTType) throws -> Snapshot {
        Snapshot(content: content, assetsFileWrapper: assetsFileWrapper)
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        if configuration.contentType == .textBundle {
            let root = FileWrapper(directoryWithFileWrappers: [:])

            let infoData = try JSONEncoder().encode(
                TextBundleInfo(creatorIdentifier: Bundle.main.bundleIdentifier))
            let infoWrapper = FileWrapper(regularFileWithContents: infoData)
            infoWrapper.preferredFilename = "info.json"
            root.addFileWrapper(infoWrapper)

            let textData = snapshot.content.data(using: .utf8) ?? Data()
            let textWrapper = FileWrapper(regularFileWithContents: textData)
            textWrapper.preferredFilename = "text.md"
            root.addFileWrapper(textWrapper)

            if let assets = snapshot.assetsFileWrapper {
                assets.preferredFilename = "assets"
                root.addFileWrapper(assets)
            }

            return root
        }

        return FileWrapper(regularFileWithContents: snapshot.content.data(using: .utf8) ?? Data())
    }
}
