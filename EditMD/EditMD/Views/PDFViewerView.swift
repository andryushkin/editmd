import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

/// Image formats shown by EditMD's read-only media viewer. The list matches
/// the formats accepted for local Markdown images in Preview.
let supportedImageFileExtensions: Set<String> = [
    "svg", "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp",
]

/// True for an image the native viewer knows how to open.
func isImageFile(_ url: URL) -> Bool {
    supportedImageFileExtensions.contains(url.pathExtension.lowercased())
}

/// Concrete open-panel types rather than broad `public.image`: a file selected
/// in the panel must also pass `isImageFile` and reach the image viewer.
func supportedImageContentTypes() -> [UTType] {
    supportedImageFileExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
}

/// True for a `.pdf` file. PDFs are read-only viewer targets: listed in the
/// sidebar next to markdown, resolvable via wiki-links, and shown through
/// PDFKit — they never reach `DocumentRegistry` / the text editor.
func isPDFFile(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "pdf"
}

/// Sidebar / folder-card glyph for every directly displayable file type.
func sidebarFileIcon(for url: URL) -> String {
    if isPDFFile(url) { return "doc.richtext" }
    if isImageFile(url) { return "photo" }
    return "doc.text"
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

// MARK: - Image viewer

/// Scrollable native image canvas. `NSImage` supports the raster formats in
/// `supportedImageFileExtensions` and SVG on the app's supported macOS range.
/// The document view keeps the image at its intrinsic size; NSScrollView owns
/// pinch-to-zoom and panning, and initially fits large images to the viewport.
private final class ImageCanvasView: NSView {
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var loadedURL: URL?
    private var loadedModificationDate: Date?
    private var loadedFileSize: Int?
    private var needsInitialFit = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.automaticallyAdjustsContentInsets = false

        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleNone
        imageView.animates = true

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 4
        statusLabel.isHidden = true

        addSubview(scrollView)
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        statusLabel.frame = bounds.insetBy(dx: 32, dy: 32)
        if needsInitialFit, bounds.width > 0, bounds.height > 0 {
            needsInitialFit = false
            fitImage()
        }
    }

    func display(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate
        let size = values?.fileSize
        guard loadedURL?.standardizedFileURL != url.standardizedFileURL
                || loadedModificationDate != date || loadedFileSize != size else { return }
        loadedURL = url
        loadedModificationDate = date
        loadedFileSize = size

        guard FileManager.default.fileExists(atPath: url.path) else {
            showFailure("Файл не найден\n\((url.path as NSString).abbreviatingWithTildeInPath)")
            return
        }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite else {
            showFailure("Не удалось отобразить изображение\n\(url.lastPathComponent)")
            return
        }

        statusLabel.isHidden = true
        scrollView.isHidden = false
        imageView.image = image
        imageView.setAccessibilityLabel(url.lastPathComponent)
        imageView.frame = NSRect(origin: .zero, size: image.size)
        scrollView.documentView = imageView
        scrollView.magnification = 1
        needsInitialFit = true
        needsLayout = true
    }

    private func showFailure(_ message: String) {
        imageView.image = nil
        scrollView.documentView = nil
        scrollView.isHidden = true
        statusLabel.stringValue = message
        statusLabel.isHidden = false
    }

    private func fitImage() {
        guard let image = imageView.image else { return }
        let viewport = scrollView.contentSize
        guard viewport.width > 0, viewport.height > 0 else { return }
        let scale = min(1, viewport.width / image.size.width, viewport.height / image.size.height)
        scrollView.setMagnification(max(scrollView.minMagnification, scale),
                                    centeredAt: NSPoint(x: image.size.width / 2,
                                                        y: image.size.height / 2))
    }
}

private struct NativeImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView()
        view.display(url)
        return view
    }

    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.display(url)
    }
}

/// Read-only image viewer. It mirrors `PDFViewerHost`: the main window keeps
/// the workspace sidebar, while Finder/Lite windows show only the image.
struct ImageViewerHost: View {
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
            NativeImageView(url: fileURL)
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
