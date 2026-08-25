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
