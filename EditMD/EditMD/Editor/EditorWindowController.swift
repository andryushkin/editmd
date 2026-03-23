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

    private static let segmentIdentifier = NSToolbarItem.Identifier("editPreviewSegment")

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.segmentIdentifier else { return nil }

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
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.segmentIdentifier, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.segmentIdentifier, .flexibleSpace]
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        guard let editorVC = contentViewController as? EditorViewController else { return }
        editorVC.setMode(sender.selectedSegment == 0 ? .edit : .preview)
    }
}
