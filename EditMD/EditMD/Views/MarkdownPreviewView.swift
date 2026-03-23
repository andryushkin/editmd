import AppKit
import SwiftUI
import MarkdownUI

// MARK: - Local image provider for .textbundle

struct TextBundleImageProvider: ImageProvider {
    let assetsURL: URL?

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        AsyncImage(url: resolvedURL(url)) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Color.clear
        }
    }

    private func resolvedURL(_ url: URL?) -> URL? {
        guard let assetsURL, let url, url.scheme == nil else { return url }
        let local = assetsURL.appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: local.path) ? local : url
    }
}

// MARK: - SwiftUI Preview View

struct MarkdownPreviewView: View {
    let text: String
    let assetsURL: URL?

    var body: some View {
        ScrollView {
            Markdown(text)
                .markdownTheme(.gitHub)
                .markdownImageProvider(TextBundleImageProvider(assetsURL: assetsURL))
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
        let hosting = NSHostingView(rootView: MarkdownPreviewView(text: "", assetsURL: nil))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hostingView = hosting
        view = hosting
    }

    func update(text: String, assetsURL: URL?) {
        hostingView.rootView = MarkdownPreviewView(text: text, assetsURL: assetsURL)
    }
}
