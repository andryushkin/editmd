import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

/// One source of truth for viewer routing, picker types and Preview data URIs.
let supportedImageMIMETypes: [String: String] = [
    "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp",
    "heic": "image/heic", "tiff": "image/tiff", "tif": "image/tiff",
    "bmp": "image/bmp",
]
let supportedImageFileExtensions = Set(supportedImageMIMETypes.keys)

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
        return markdownImageSyntax(source: source, alt: chosenAlt)
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
        let diskAssets = imageAssets(in: assetsDir)
        let existing = Set(
            (assets.fileWrappers ?? [:]).keys.map { $0.lowercased() }
                + diskAssets.map { $0.url.lastPathComponent.lowercased() }
        )
        if case .file(let sourceURL) = candidate,
           sourceURL.deletingLastPathComponent().standardizedFileURL
                == assetsDir.standardizedFileURL,
           existing.contains(sourceURL.lastPathComponent.lowercased()) {
            let data = try imageCandidateData(candidate)
            addImageAssetWrapper(named: sourceURL.lastPathComponent,
                                 data: data, to: assets)
            document.assetsFileWrapper = assets
            return ImageInsertionAsset(source: "assets/\(sourceURL.lastPathComponent)",
                                       suggestedAlt: alt)
        }
        let data = try imageCandidateData(candidate)
        if let match = identicalImageAsset(in: diskAssets, candidate: .data(data, filename: baseName)) {
            addImageAssetWrapper(named: match, data: data, to: assets)
            document.assetsFileWrapper = assets
            return ImageInsertionAsset(source: "assets/\(match)", suggestedAlt: alt)
        }
        let name = uniqueImageAssetFilename(baseName) {
            existing.contains($0.lowercased())
                || FileManager.default.fileExists(atPath: assetsDir.appendingPathComponent($0).path)
        }
        // Make the asset visible to Visual/Preview immediately; their image
        // resolvers read package assets from disk. The matching FileWrapper
        // below ensures the next atomic textbundle autosave preserves it.
        try data.write(to: assetsDir.appendingPathComponent(name), options: .atomic)
        addImageAssetWrapper(named: name, data: data, to: assets)
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
    let diskAssets = imageAssets(in: assetsDir)
    if let match = identicalImageAsset(in: diskAssets, candidate: candidate) {
        return ImageInsertionAsset(source: "assets/\(match)", suggestedAlt: alt)
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

private func imageCandidateData(_ candidate: ImageAssetCandidate) throws -> Data {
    let data: Data
    switch candidate {
    case .file(let url): data = try Data(contentsOf: url)
    case .data(let bytes, _): data = bytes
    }
    guard !data.isEmpty else { throw ImageInsertionError.unreadableImage }
    return data
}

private func addImageAssetWrapper(named name: String, data: Data,
                                  to assets: FileWrapper) {
    guard assets.fileWrappers?[name] == nil else { return }
    let wrapper = FileWrapper(regularFileWithContents: data)
    wrapper.preferredFilename = name
    assets.preferredFilename = "assets"
    assets.addFileWrapper(wrapper)
}

private struct ExistingImageAsset {
    let url: URL
    let size: Int
}

/// Enumerate once and retain the prefetched file size. Byte comparison only
/// touches files whose size can actually match the incoming image.
private func imageAssets(in directory: URL) -> [ExistingImageAsset] {
    let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
    let items = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles])) ?? []
    return items.compactMap { url in
        guard isImageFile(url),
              let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let size = values.fileSize
        else { return nil }
        return ExistingImageAsset(url: url, size: size)
    }
}

/// Re-inserting the same file/pixels reuses the existing attachment instead of
/// growing `assets/logo-2.png`, `logo-3.png`, … with identical bytes.
private func identicalImageAsset(in assets: [ExistingImageAsset],
                                 candidate: ImageAssetCandidate) -> String? {
    let candidateSize: Int?
    switch candidate {
    case .file(let source):
        candidateSize = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    case .data(let bytes, _):
        candidateSize = bytes.count
    }
    guard let candidateSize else { return nil }

    for asset in assets where asset.size == candidateSize {
        switch candidate {
        case .file(let source):
            if FileManager.default.contentsEqual(atPath: source.path, andPath: asset.url.path) {
                return asset.url.lastPathComponent
            }
        case .data(let bytes, _):
            if (try? Data(contentsOf: asset.url)) == bytes {
                return asset.url.lastPathComponent
            }
        }
    }
    return nil
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

/// Shared workspace/sidebar chrome for read-only PDF and image viewers.
private let mediaSidebarWidthRange = 150.0...400.0

private struct MediaViewerHost<Viewer: View>: View {
    let fileURL: URL
    let allowsSidebar: Bool
    let viewer: Viewer

    @ObservedObject private var workspace = WorkspaceModel.shared
    @AppStorage("sidebarVisible") private var sidebarVisible = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 220.0

    init(fileURL: URL, allowsSidebar: Bool,
         @ViewBuilder viewer: () -> Viewer) {
        self.fileURL = fileURL
        self.allowsSidebar = allowsSidebar
        self.viewer = viewer()
    }

    var body: some View {
        HStack(spacing: 0) {
            if allowsSidebar && sidebarVisible {
                WorkspaceSidebar(
                    workspace: workspace,
                    activeURL: fileURL,
                    onOpen: { AppState.shared.openInMainWindow($0) },
                    onOpenFolder: { AppState.shared.openInMainWindow($0) }
                )
                .frame(width: sidebarWidth)
                paneDivider { x in
                    sidebarWidth = min(mediaSidebarWidthRange.upperBound,
                                       max(mediaSidebarWidthRange.lowerBound, Double(x)))
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

/// Window content for a PDF: main window gets the workspace sidebar; lite
/// windows show only the read-only PDFKit viewer.
struct PDFViewerHost: View {
    let fileURL: URL
    var allowsSidebar: Bool = true

    var body: some View {
        MediaViewerHost(fileURL: fileURL, allowsSidebar: allowsSidebar) {
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
    }
}

// MARK: - Image viewer

struct ImageFileVersion: Equatable, Sendable {
    let modificationDate: Date
    let size: Int
}

/// Lightweight disk identity used to decide whether the current image needs
/// another read. Callers run this together with file loading off the main actor.
func imageFileVersion(at url: URL) -> ImageFileVersion? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let modificationDate = attributes[.modificationDate] as? Date,
          let size = (attributes[.size] as? NSNumber)?.intValue
    else { return nil }
    return ImageFileVersion(modificationDate: modificationDate, size: size)
}

/// Scrollable native image canvas. `NSImage` supports the raster formats in
/// `supportedImageFileExtensions` and SVG on the app's supported macOS range.
/// The document view keeps the image at its intrinsic size; NSScrollView owns
/// pinch-to-zoom and panning, and initially fits large images to the viewport.
private final class ImageCanvasView: NSView {
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var requestedURL: URL?
    private var displayedVersion: ImageFileVersion?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var needsInitialFit = false

    private enum LoadResult: Sendable {
        case data(Data, ImageFileVersion)
        case unchanged
        case missing
        case unreadable
    }

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

    deinit { loadTask?.cancel() }

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
        let requested = url.standardizedFileURL
        guard requestedURL != requested || loadTask == nil else { return }

        let previousVersion = requestedURL == requested ? displayedVersion : nil
        let changedURL = requestedURL != requested
        requestedURL = requested
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        if changedURL { showLoading() }

        loadTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> LoadResult in
                guard let version = imageFileVersion(at: requested) else { return .missing }
                guard version != previousVersion else { return .unchanged }
                guard let data = try? Data(contentsOf: requested), !data.isEmpty
                else { return .unreadable }
                return .data(data, version)
            }.value
            guard !Task.isCancelled, let self,
                  self.loadGeneration == generation,
                  self.requestedURL == requested else { return }
            self.loadTask = nil
            switch result {
            case .unchanged:
                return
            case .missing:
                self.displayedVersion = nil
                self.showFailure("Файл не найден\n\((requested.path as NSString).abbreviatingWithTildeInPath)")
            case .unreadable:
                self.displayedVersion = nil
                self.showFailure("Не удалось прочитать изображение\n\(requested.lastPathComponent)")
            case .data(let data, let version):
                guard let image = NSImage(data: data), image.size.width > 0,
                      image.size.height > 0, image.size.width.isFinite,
                      image.size.height.isFinite else {
                    self.displayedVersion = nil
                    self.showFailure("Не удалось отобразить изображение\n\(requested.lastPathComponent)")
                    return
                }
                self.displayedVersion = version
                self.show(image, named: requested.lastPathComponent)
            }
        }
    }

    private func show(_ image: NSImage, named name: String) {
        statusLabel.isHidden = true
        scrollView.isHidden = false
        imageView.image = image
        imageView.setAccessibilityLabel(name)
        imageView.frame = NSRect(origin: .zero, size: image.size)
        scrollView.documentView = imageView
        scrollView.magnification = 1
        needsInitialFit = true
        needsLayout = true
    }

    private func showLoading() {
        imageView.image = nil
        scrollView.documentView = nil
        scrollView.isHidden = true
        statusLabel.stringValue = "Загрузка…"
        statusLabel.isHidden = false
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

    var body: some View {
        MediaViewerHost(fileURL: fileURL, allowsSidebar: allowsSidebar) {
            NativeImageView(url: fileURL)
        }
    }
}
