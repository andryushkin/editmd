import AppKit

final class MarkdownDocument: NSDocument {

    // nonisolated(unsafe) because read(from:ofType:) is called on a background thread by NSDocument
    nonisolated(unsafe) var content: String = ""

    // MARK: - NSDocument

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let wc = EditorWindowController(document: self)
        addWindowController(wc)
    }

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
}
