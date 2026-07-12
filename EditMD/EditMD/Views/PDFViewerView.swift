import SwiftUI
import PDFKit

/// True for a `.pdf` file. PDFs are read-only viewer targets: listed in the
/// sidebar next to markdown, resolvable via wiki-links, and shown through
/// PDFKit — they never reach `DocumentRegistry` / the text editor.
func isPDFFile(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "pdf"
}

/// Sidebar / folder-card glyph for a file row (PDFs get their own icon).
func sidebarFileIcon(for url: URL) -> String {
    isPDFFile(url) ? "doc.richtext" : "doc.text"
}

/// PDFKit viewer wrapped for SwiftUI. The document is reloaded only when the
/// URL actually changes so SwiftUI update passes don't reset scroll/zoom.
struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL?.standardizedFileURL != url.standardizedFileURL {
            view.document = PDFDocument(url: url)
        }
    }
}

/// Window content for a PDF: main window gets the same workspace sidebar as
/// the editor (center pane = viewer), lite windows pass `allowsSidebar: false`.
/// Mirrors `FolderInfoHost` — no document, so File ▸ Save / Format stay
/// disabled via nil focused values.
struct PDFViewerHost: View {
    let fileURL: URL
    var allowsSidebar: Bool = true

    @ObservedObject private var workspace = WorkspaceModel.shared
    @AppStorage("sidebarVisible") private var sidebarVisible = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 220.0

    private static let sidebarWidthRange = 150.0...400.0

    var body: some View {
        HStack(spacing: 0) {
            if allowsSidebar && sidebarVisible {
                WorkspaceSidebar(
                    workspace: workspace,
                    outlineContent: "",
                    activeURL: fileURL,
                    onOpen: { AppState.shared.openInMainWindow($0) },
                    onOpenFolder: { AppState.shared.openInMainWindow($0) },
                    onJump: { _ in }
                )
                .frame(width: sidebarWidth)
                paneDivider { x in
                    sidebarWidth = min(Self.sidebarWidthRange.upperBound,
                                       max(Self.sidebarWidthRange.lowerBound, Double(x)))
                }
                .zIndex(1)
            }
            viewer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.15), value: sidebarVisible)
        .background(WindowAccessor { window in
            window.representedURL = fileURL
            window.title = fileURL.lastPathComponent
        })
        .toolbar {
            if allowsSidebar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        sidebarVisible.toggle()
                    } label: {
                        Label("Toggle Sidebar", systemImage: "sidebar.left")
                    }
                    .help("Toggle Sidebar (⌃⌘S)")
                }
            }
        }
        .focusedSceneValue(\.sidebarVisible, $sidebarVisible)
    }

    @ViewBuilder private var viewer: some View {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            PDFKitView(url: fileURL)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Файл не найден")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text((fileURL.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    private func paneDivider(onDrag: @escaping (CGFloat) -> Void) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { onDrag($0.location.x) }
                    )
            }
    }
}
