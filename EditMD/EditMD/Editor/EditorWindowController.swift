import AppKit

final class EditorWindowController: NSWindowController {

    private let markdownDocument: MarkdownDocument

    init(document: MarkdownDocument) {
        self.markdownDocument = document

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 400, height: 300)
        window.center()
        window.setFrameAutosaveName("EditorWindow")
        window.titleVisibility = .visible
        window.toolbarStyle = .unifiedCompact

        super.init(window: window)

        let editorVC = EditorViewController(document: markdownDocument)
        contentViewController = editorVC
        window.contentViewController = editorVC

        setupToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }
}

// MARK: - NSToolbarDelegate

extension EditorWindowController: NSToolbarDelegate {

    static let segmentIdentifier = NSToolbarItem.Identifier("editPreviewSegment")
    static let cutIdentifier     = NSToolbarItem.Identifier("cutItem")
    static let copyIdentifier    = NSToolbarItem.Identifier("copyItem")
    static let pasteIdentifier   = NSToolbarItem.Identifier("pasteItem")

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.segmentIdentifier:
            let segment = NSSegmentedControl(
                labels: ["Edit", "Preview"],
                trackingMode: .selectOne,
                target: self,
                action: #selector(segmentChanged(_:))
            )
            segment.selectedSegment = 0
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = segment
            item.label = "Mode"
            return item

        case Self.cutIdentifier:
            return makeClipboardItem(identifier: itemIdentifier,
                                     label: "Cut",
                                     symbol: "scissors",
                                     action: #selector(NSText.cut(_:)))
        case Self.copyIdentifier:
            return makeClipboardItem(identifier: itemIdentifier,
                                     label: "Copy",
                                     symbol: "doc.on.doc",
                                     action: #selector(NSText.copy(_:)))
        case Self.pasteIdentifier:
            return makeClipboardItem(identifier: itemIdentifier,
                                     label: "Paste",
                                     symbol: "doc.on.clipboard",
                                     action: #selector(NSText.paste(_:)))
        default:
            return nil
        }
    }

    private func makeClipboardItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.target = nil
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.cutIdentifier, Self.copyIdentifier, Self.pasteIdentifier,
         .flexibleSpace, Self.segmentIdentifier, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.cutIdentifier, Self.copyIdentifier, Self.pasteIdentifier,
         Self.segmentIdentifier, .flexibleSpace]
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        guard let editorVC = contentViewController as? EditorViewController else { return }
        editorVC.setMode(sender.selectedSegment == 0 ? .edit : .preview)
    }
}
