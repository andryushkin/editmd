import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdown = UTType("net.daringfireball.markdown")!
    static let textBundle = UTType("org.textbundle.package")!
}

final class MarkdownDocument: ReferenceFileDocument {

    // nonisolated(unsafe) because ReferenceFileDocument protocol methods are nonisolated.
    // didSet publishes the change so SwiftUI-only readers (the outline sidebar,
    // the split's live preview, the Preview status bar) refresh on every edit —
    // editors write from the main thread, and init assignments skip didSet.
    nonisolated(unsafe) var content: String {
        didSet {
            guard content != oldValue else { return }
            objectWillChange.send()
        }
    }
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
        let (text, assets) = try parseMarkdownWrapper(
            configuration.file,
            isTextBundle: configuration.contentType == .textBundle)
        content = text
        assetsFileWrapper = assets
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
