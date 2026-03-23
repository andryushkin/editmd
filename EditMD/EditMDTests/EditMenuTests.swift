import XCTest
@testable import EditMD

// MARK: - Toolbar structure (tests EditorWindowController)

@MainActor
final class EditToolbarTests: XCTestCase {

    private var wc: EditorWindowController!
    private var toolbar: NSToolbar!

    override func setUp() {
        super.setUp()
        let doc = MarkdownDocument()
        wc = EditorWindowController(document: doc)
        toolbar = wc.window?.toolbar
    }

    func testToolbarDefaultIdentifiersContainCut() {
        let ids = toolbar?.delegate?.toolbarDefaultItemIdentifiers?(toolbar!)
        XCTAssertTrue(ids?.contains(EditorWindowController.cutIdentifier) == true)
    }

    func testToolbarDefaultIdentifiersContainCopy() {
        let ids = toolbar?.delegate?.toolbarDefaultItemIdentifiers?(toolbar!)
        XCTAssertTrue(ids?.contains(EditorWindowController.copyIdentifier) == true)
    }

    func testToolbarDefaultIdentifiersContainPaste() {
        let ids = toolbar?.delegate?.toolbarDefaultItemIdentifiers?(toolbar!)
        XCTAssertTrue(ids?.contains(EditorWindowController.pasteIdentifier) == true)
    }

    func testCutToolbarItemAction() {
        let item = toolbarItem(for: EditorWindowController.cutIdentifier)
        XCTAssertEqual(item?.action, #selector(NSText.cut(_:)))
        XCTAssertNil(item?.target)
    }

    func testCopyToolbarItemAction() {
        let item = toolbarItem(for: EditorWindowController.copyIdentifier)
        XCTAssertEqual(item?.action, #selector(NSText.copy(_:)))
        XCTAssertNil(item?.target)
    }

    func testPasteToolbarItemAction() {
        let item = toolbarItem(for: EditorWindowController.pasteIdentifier)
        XCTAssertEqual(item?.action, #selector(NSText.paste(_:)))
        XCTAssertNil(item?.target)
    }

    private func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        toolbar?.delegate?.toolbar?(toolbar!, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: false)
    }
}
