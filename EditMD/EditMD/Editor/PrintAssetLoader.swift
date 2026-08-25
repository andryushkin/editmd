import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Answers the page renderer's requests for the files a document refers to.
///
/// **Every name reaching this type is untrusted.** The renderer opens nothing
/// and checks nothing: a name is whatever somebody typed between the brackets,
/// and `../../../../etc/passwd`, `~/.ssh/id_rsa` and `file:///etc/passwd` all
/// arrive intact and spelled exactly that way. Deciding what a name may reach is
/// this app's job and cannot be delegated downwards, so the rules live here and
/// nowhere else.
///
/// The set of files that print is deliberately the set that appears in
/// Preview — same extensions, same size cap — so that a page which looks
/// complete on screen does not lose a picture on paper for a reason nobody
/// could see.
struct PrintAssetLoader: Sendable {

    /// The document's folder (the package itself for a textbundle), exactly as
    /// Preview resolves against it. nil for an unsaved document: nothing
    /// resolves, and the renderer reports each missing file as a warning.
    let baseDir: URL?

    /// The bytes of one asset, or nil when the name resolves to nothing this
    /// document may have.
    ///
    /// `name` is already percent-decoded by the renderer — a document writing
    /// `network%20map.png` asks for the file with a space in it — so decoding it
    /// again here would turn a literal `%20` in a real file name into a space
    /// and open the wrong file.
    func bytes(forAssetNamed name: String) -> Data? {
        guard let baseDir, !name.isEmpty else { return nil }
        // A name with a scheme is not a path, and one that starts at the root or
        // at a home directory is not *this document's* path. Refused before any
        // resolution, so nothing below has to reason about them.
        guard URL(string: name)?.scheme == nil,
              !name.hasPrefix("/"), !name.hasPrefix("~") else { return nil }

        let candidate = baseDir.appendingPathComponent(name)
        // Symlinks are resolved on **both** sides before the two are compared.
        // Standardizing alone only folds `..` away textually: a link inside the
        // document's own folder pointing anywhere on the disk would survive it
        // and read as an ordinary child.
        //
        // The comparison itself is `pathIsContained`, the same one the control
        // socket and the offline vault use. It canonicalizes the firmlink
        // prefix, which this needs and a component walk of its own would not
        // have: resolution leaves `/private/tmp` on some paths and `/tmp` on
        // others, and a folder under either would then read as outside itself.
        let base = baseDir.resolvingSymlinksInPath().standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        // `pathIsContained` is true for the folder itself, which is right for a
        // workspace scope and wrong here: a folder is not one of its own
        // pictures. Said outright rather than left to the file-type and
        // regular-file checks below to reject by accident.
        guard resolved != base, pathIsContained(resolved.path, in: base.path) else { return nil }

        let format = resolved.pathExtension.lowercased()
        guard supportedImageFileExtensions.contains(format) else { return nil }

        // Stat before read, and the size comes from the same stat: an oversized
        // file is refused without its bytes ever entering the process, and a
        // directory or a device named as a picture is refused before something
        // tries to read one.
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey,
                                                                 .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= maxInlineImageBytes
        else { return nil }

        guard let data = try? Data(contentsOf: resolved), data.count <= maxInlineImageBytes
        else { return nil }

        guard !PDMCore.readableImageFormats.contains(format) else { return data }
        // A picture macOS reads and the renderer does not. Before this went
        // through the page renderer these printed, because a web view drew them;
        // now they would be a blank space and a warning about a file that is
        // sitting right there. HEIC in particular is what the cameras on these
        // machines produce by default.
        //
        // Re-encoded under the *same* key: the renderer matches the bytes to the
        // name it asked for, and the name belongs to the document.
        //
        // The cap is applied again to the result, because the result is what
        // crosses the boundary: PNG of a 7.9 MB photograph is tens of megabytes,
        // and a file that was refused for its size when read must not walk back
        // in three times larger for having been converted.
        guard let converted = Self.pngEncoded(data), converted.count <= maxInlineImageBytes
        else { return nil }
        return converted
    }

    /// One picture re-encoded as PNG, or nil when the system cannot read it —
    /// in which case nothing is handed over and the renderer reports the file as
    /// missing, which is the truth from its side.
    ///
    /// PNG rather than JPEG on purpose: these are screenshots and diagrams as
    /// often as photographs, and a lossy step nobody asked for would show.
    ///
    /// Decoded through the thumbnail path, at the image's own pixel size, so
    /// that the EXIF orientation is applied. `CGImageSourceCreateImageAtIndex`
    /// hands back the stored pixels and leaves the rotation in a tag that PNG
    /// has nowhere to put — a portrait photograph from a phone would print on
    /// its side. `…FromImageAlways` keeps it from answering with an embedded
    /// preview instead of the picture.
    static func pngEncoded(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixels = [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight]
            .compactMap { properties?[$0] as? Int }
        guard let longestSide = pixels.max(), longestSide > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longestSide,
              ] as CFDictionary)
        else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}
