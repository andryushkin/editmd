import Foundation

/// One source of truth for viewer routing, picker types and Preview data URIs.
/// Pure Foundation — the wiki index (and the offline editmdctl engine) needs
/// the extension set without pulling AppKit.
let supportedImageMIMETypes: [String: String] = [
    "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp",
    "heic": "image/heic", "tiff": "image/tiff", "tif": "image/tiff",
    "bmp": "image/bmp",
]
let supportedImageFileExtensions = Set(supportedImageMIMETypes.keys)

/// The folder a document's relative image paths resolve against.
///
/// One function for every path that draws a picture — Preview, Visual and
/// Print — because the answer has to be the same on the screen and on the
/// paper, and three copies of a one-line rule agree on the day they are
/// written and not after. The package itself for a `.textbundle`, whose
/// sources say `assets/…`; the containing folder for anything else; nothing
/// for a document with no path yet.
///
/// The extension is compared case-insensitively, the way the file reader
/// compares it (`MarkdownFileIO`). The three copies this replaces did not:
/// `Note.TEXTBUNDLE` was opened as a package and then had its pictures looked
/// for beside the package rather than inside it, so the document read fine and
/// its images were missing in all three places at once.
func documentAssetBaseDir(for fileURL: URL?) -> URL? {
    guard let fileURL else { return nil }
    return fileURL.pathExtension.lowercased() == "textbundle"
        ? fileURL
        : fileURL.deletingLastPathComponent()
}

/// Largest file Preview will inline and Print will embed.
///
/// One number for both on purpose: a picture that shows on screen and vanishes
/// on paper — or the other way round — is a difference nobody can explain from
/// the document.
let maxInlineImageBytes = 8_000_000

/// True for an image the native viewer knows how to open.
func isImageFile(_ url: URL) -> Bool {
    supportedImageFileExtensions.contains(url.pathExtension.lowercased())
}
