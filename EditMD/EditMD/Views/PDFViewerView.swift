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

// MARK: - Image insertion assets

/// A stored image ready to become Markdown. `source` is always relative to the
/// document (`assets/name.ext`), so Preview, Visual and exported PDF resolve it
/// the same way.
struct ImageInsertionAsset: Equatable {
    let source: String
    let suggestedAlt: String

    func markdown(alt requestedAlt: String? = nil) -> String {
        let rawAlt = requestedAlt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenAlt = rawAlt.flatMap { $0.isEmpty ? nil : $0 } ?? suggestedAlt
        let alt = chosenAlt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let destination = source.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" })
            ? "<\(source)>" : source
        return "![\(alt)](\(destination))"
    }
}

enum ImageAssetCandidate {
    case file(URL)
    case data(Data, filename: String)

    var filename: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .data(_, let filename): return filename
        }
    }
}

enum ImageInsertionError: LocalizedError {
    case unsavedDocument
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unsavedDocument: return "Сначала сохраните документ, чтобы создать папку assets."
        case .unreadableImage: return "Не удалось прочитать изображение."
        }
    }
}

/// File picker used by the action-strip button.
@MainActor
func chooseImageForInsertion(document: MarkdownDocument,
                             fileURL: URL?) -> ImageInsertionAsset? {
    guard let fileURL else {
        presentImageInsertionError(ImageInsertionError.unsavedDocument)
        return nil
    }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = supportedImageContentTypes()
    panel.allowsMultipleSelection = false
    panel.directoryURL = fileURL.pathExtension.lowercased() == "textbundle"
        ? fileURL.appendingPathComponent("assets", isDirectory: true)
        : fileURL.deletingLastPathComponent()
    guard panel.runModal() == .OK, let selected = panel.url else { return nil }
    do {
        return try storeImageAsset(.file(selected), document: document, fileURL: fileURL)
    } catch {
        presentImageInsertionError(error)
        return nil
    }
}

/// Extracts an actual image from the pasteboard. Finder file URLs keep their
/// original format; screenshots and copied bitmap pixels prefer PNG. Returns
/// nil for ordinary text/HTML so the editor's existing paste path can continue.
@MainActor
func imageCandidate(from pasteboard: NSPasteboard) -> ImageAssetCandidate? {
    for item in pasteboard.pasteboardItems ?? [] {
        if let value = item.string(forType: .fileURL),
           let url = URL(string: value), isImageFile(url) {
            return .file(url)
        }
    }

    let typed: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
        (NSPasteboard.PasteboardType("org.webmproject.webp"), "webp"),
        (NSPasteboard.PasteboardType("public.svg-image"), "svg"),
        (NSPasteboard.PasteboardType("public.heic"), "heic"),
    ]
    for (type, ext) in typed {
        if let data = pasteboard.data(forType: type), !data.isEmpty {
            return .data(data, filename: pastedImageFilename(extension: ext))
        }
    }

    // macOS screenshots commonly expose TIFF even when no PNG flavor exists.
    // Normalize that payload to PNG: dramatically smaller and universally
    // rendered by every EditMD surface.
    if let tiff = pasteboard.data(forType: .tiff),
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        return .data(png, filename: pastedImageFilename(extension: "png"))
    }
    return nil
}

@MainActor
func storeImageAsset(_ candidate: ImageAssetCandidate,
                     document: MarkdownDocument,
                     fileURL: URL?) throws -> ImageInsertionAsset {
    guard let fileURL else { throw ImageInsertionError.unsavedDocument }
    let rawName = candidate.filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawName.isEmpty else { throw ImageInsertionError.unreadableImage }
    let baseName = URL(fileURLWithPath: rawName).lastPathComponent
    let alt = URL(fileURLWithPath: baseName).deletingPathExtension().lastPathComponent

    if fileURL.pathExtension.lowercased() == "textbundle" {
        let assetsDir = fileURL.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let assets = document.assetsFileWrapper
            ?? FileWrapper(directoryWithFileWrappers: [:])
        let existing = Set((assets.fileWrappers ?? [:]).keys.map { $0.lowercased() })
        if case .file(let sourceURL) = candidate,
           sourceURL.deletingLastPathComponent().standardizedFileURL
                == assetsDir.standardizedFileURL,
           existing.contains(sourceURL.lastPathComponent.lowercased()) {
            return ImageInsertionAsset(source: "assets/\(sourceURL.lastPathComponent)",
                                       suggestedAlt: alt)
        }
        let name = uniqueImageAssetFilename(baseName) {
            existing.contains($0.lowercased())
                || FileManager.default.fileExists(atPath: assetsDir.appendingPathComponent($0).path)
        }
        let data: Data
        switch candidate {
        case .file(let url):
            guard let read = try? Data(contentsOf: url), !read.isEmpty
            else { throw ImageInsertionError.unreadableImage }
            data = read
        case .data(let bytes, _):
            guard !bytes.isEmpty else { throw ImageInsertionError.unreadableImage }
            data = bytes
        }
        // Make the asset visible to Visual/Preview immediately; their image
        // resolvers read package assets from disk. The matching FileWrapper
        // below ensures the next atomic textbundle autosave preserves it.
        try data.write(to: assetsDir.appendingPathComponent(name), options: .atomic)
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = name
        assets.preferredFilename = "assets"
        assets.addFileWrapper(wrapper)
        document.assetsFileWrapper = assets
        return ImageInsertionAsset(source: "assets/\(name)", suggestedAlt: alt)
    }

    let assetsDir = fileURL.deletingLastPathComponent()
        .appendingPathComponent("assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

    if case .file(let sourceURL) = candidate,
       sourceURL.deletingLastPathComponent().standardizedFileURL == assetsDir.standardizedFileURL {
        return ImageInsertionAsset(source: "assets/\(sourceURL.lastPathComponent)",
                                   suggestedAlt: alt)
    }

    let name = uniqueImageAssetFilename(baseName) {
        FileManager.default.fileExists(atPath: assetsDir.appendingPathComponent($0).path)
    }
    let destination = assetsDir.appendingPathComponent(name)
    switch candidate {
    case .file(let sourceURL):
        try FileManager.default.copyItem(at: sourceURL, to: destination)
    case .data(let bytes, _):
        guard !bytes.isEmpty else { throw ImageInsertionError.unreadableImage }
        try bytes.write(to: destination, options: .atomic)
    }
    return ImageInsertionAsset(source: "assets/\(name)", suggestedAlt: alt)
}

func uniqueImageAssetFilename(_ original: String,
                              exists: (String) -> Bool) -> String {
    guard exists(original) else { return original }
    let ns = original as NSString
    let ext = ns.pathExtension
    let stem = ns.deletingPathExtension
    var index = 2
    while true {
        let candidate = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
        if !exists(candidate) { return candidate }
        index += 1
    }
}

private func pastedImageFilename(extension ext: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMddHHmmss"
    return "Pasted image \(formatter.string(from: Date())).\(ext)"
}

@MainActor
func presentImageInsertionError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Не удалось добавить изображение"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
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
