import AppKit
import SwiftUI
import MarkdownUI

// MARK: - SwiftUI Preview View

struct MarkdownPreviewView: View {
    let text: String

    var body: some View {
        ScrollView {
            Markdown(text)
                .markdownTheme(.gitHub)
                .padding(.horizontal, 48)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - AppKit ViewController wrapper

final class MarkdownPreviewViewController: NSViewController {

    private var hostingView: NSHostingView<MarkdownPreviewView>!

    override func loadView() {
        let hosting = NSHostingView(rootView: MarkdownPreviewView(text: ""))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hostingView = hosting
        view = hosting
    }

    func update(text: String) {
        hostingView.rootView = MarkdownPreviewView(text: text)
    }
}
