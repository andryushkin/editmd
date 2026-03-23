import AppKit
import SwiftUI

enum EditorMode {
    case edit, preview
}

final class EditorViewController: NSViewController {

    private let document: MarkdownDocument
    private var mode: EditorMode = .edit

    // Child view controllers
    private lazy var editorVC = MarkdownEditorViewController(document: document)
    private lazy var previewVC = MarkdownPreviewViewController()

    init(document: MarkdownDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(editorVC)
        addChild(previewVC)

        embedFilling(editorVC.view)
        previewVC.view.isHidden = true
        view.addSubview(previewVC.view)
        previewVC.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            previewVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            previewVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Mode switching

    func setMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        mode = newMode

        switch newMode {
        case .edit:
            previewVC.view.isHidden = true
            editorVC.view.isHidden = false

        case .preview:
            let assetsURL: URL? = document.fileURL.flatMap {
                $0.pathExtension == "textbundle" ? $0.appendingPathComponent("assets") : nil
            }
            previewVC.update(text: document.content, assetsURL: assetsURL)
            editorVC.view.isHidden = true
            previewVC.view.isHidden = false
        }
    }

    // MARK: - Helpers

    private func embedFilling(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: view.topAnchor),
            subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
