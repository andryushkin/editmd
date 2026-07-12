import AppKit

/// Double-click editor for rendered formulas in Visual: a TeX field with a
/// live SwiftMath preview. ⌘⏎ (or the OK button) commits; Esc / click outside
/// cancels. Presented as a transient popover anchored to the attachment.
@MainActor
final class MathEditorPopover: NSViewController, NSTextViewDelegate, NSPopoverDelegate {

    private let display: Bool
    private let fontSize: CGFloat
    private let commit: (String) -> Void
    private let scroll = NSTextView.scrollableTextView()
    private var texView: NSTextView { scroll.documentView as! NSTextView }
    private let preview = NSImageView()
    private let status = NSTextField(labelWithString: "")
    /// Strong while shown (nothing else retains an NSPopover); the cycle
    /// popover → controller → popover is broken in popoverDidClose.
    private var popover: NSPopover?

    /// Shows the editor over `charRange` (the attachment character).
    static func present(over textView: NSTextView, charRange: NSRange,
                        tex: String, display: Bool, fontSize: CGFloat,
                        commit: @escaping (String) -> Void) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange,
                                                  actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        if rect.isEmpty {
            rect = NSRect(x: rect.origin.x, y: rect.origin.y, width: 4, height: 16)
        }

        let controller = MathEditorPopover(tex: tex, display: display,
                                           fontSize: fontSize, commit: commit)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = controller
        controller.popover = popover
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        textView.window?.makeFirstResponder(controller.texView)
    }

    private init(tex: String, display: Bool, fontSize: CGFloat,
                 commit: @escaping (String) -> Void) {
        self.display = display
        self.fontSize = fontSize
        self.commit = commit
        super.init(nibName: nil, bundle: nil)
        texView.string = tex
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        texView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        texView.isRichText = false
        texView.allowsUndo = true
        texView.delegate = self
        texView.textContainerInset = NSSize(width: 4, height: 6)
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: display ? 84 : 46).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true

        preview.imageScaling = .scaleProportionallyDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelEdit))
        let ok = NSButton(title: "OK", target: self, action: #selector(commitEdit))
        ok.keyEquivalent = "\r"
        ok.keyEquivalentModifierMask = [.command]
        let hint = NSTextField(labelWithString: "⌘⏎")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [status, spacer, hint, cancel, ok])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [scroll, preview, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        view = stack
        refreshPreview()
    }

    func textDidChange(_ notification: Notification) {
        refreshPreview()
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }

    private func refreshPreview() {
        let tex = texView.string
        if let image = MathRender.previewImage(tex: tex, display: display,
                                               fontSize: fontSize) {
            preview.image = image
            status.stringValue = ""
        } else {
            preview.image = nil
            status.stringValue = tex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Пустая формула — OK удалит её"
                : "TeX не разбирается — сохранится как текст"
        }
    }

    @objc private func commitEdit() {
        let tex = texView.string
        popover?.close()
        commit(tex)
    }

    @objc private func cancelEdit() {
        popover?.close()
    }
}
