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

    /// The one form an asset name has once it is inside this app.
    ///
    /// NFC, the form the boundary was declared in. Applied once, where a name
    /// crosses in — `PDMCore.setAssets` — and before anything looks at the
    /// disk, so that every later statement about that name is a statement
    /// about one spelling. It lives here because the rules about what a name
    /// means belong here, and it is applied there because there is the single
    /// door.
    ///
    /// What this does **not** buy, measured on this machine 28 Aug 2026 rather
    /// than assumed: opening the file. `é.png` written as U+00E9 and as
    /// U+0065 U+0301 are seven bytes and six, and APFS finds the same file for
    /// either — it stores the form a file was created with and compares
    /// without regard to form, and Swift's `==` on `String` compares by
    /// canonical equivalence too. So "the picture printed" was never the
    /// question. The question is whether the *name* is one name: it is written
    /// into the print report, it is the key an asset is filed under, and it is
    /// compared byte for byte against the same name produced elsewhere. Two
    /// spellings there are two assets, and no amount of the file system being
    /// helpful makes them one.
    static func canonicalName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

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
    /// and open the wrong file. It has also been through `canonicalName`
    /// already: normalising again here would be harmless and would put the
    /// rule in two places, which is how two places start to disagree.
    func bytes(forAssetNamed name: String) -> Data? {
        guard let baseDir, !name.isEmpty else { return nil }
        // A name with a scheme is not a path, and one that starts at the root or
        // at a home directory is not *this document's* path. Refused before any
        // resolution, so nothing below has to reason about them.
        guard URL(string: name)?.scheme == nil,
              !name.hasPrefix("/"), !name.hasPrefix("~") else { return nil }

        // OPEN FIRST, then ask every question of the thing that was opened.
        //
        // This used to touch the file system three times — resolve the path and
        // compare it, stat the path, read the path — and a name can be pointed
        // somewhere else between any two of them. Measured, not feared: a
        // probe that flipped `pic.png` between a real picture and a link out of
        // the folder read the outside bytes after **36 attempts**. Checking a
        // path and reading a path are two separate questions to the file
        // system, and nothing carries the answer of the first into the second.
        //
        // A descriptor does. `O_NOFOLLOW` refuses outright when the last
        // component is a link; `F_GETPATH` says where the opened object really
        // lives, so a link somewhere in the middle cannot smuggle it out
        // either; `fstat` and the read both speak to that same open object.
        // Whatever the name points at afterwards is somebody else's file.
        //
        // `O_NONBLOCK` so a FIFO named as a picture cannot hang the open — it
        // is refused a moment later for not being a regular file, but only if
        // the open returns at all.
        let candidate = baseDir.appendingPathComponent(name).standardizedFileURL
        let base = baseDir.resolvingSymlinksInPath().standardizedFileURL

        let descriptor = candidate.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        // Where the opened object actually is. The comparison is
        // `pathIsContained`, the same one the control socket and the offline
        // vault use: it canonicalizes the firmlink prefix, which this needs and
        // a component walk of its own would not have — resolution leaves
        // `/private/tmp` on some paths and `/tmp` on others, and a folder under
        // either would then read as outside itself.
        //
        // `pathIsContained` is true for the folder itself, which is right for a
        // workspace scope and wrong here: a folder is not one of its own
        // pictures. Said outright rather than left to the regular-file check
        // below to reject by accident.
        var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &pathBuffer) != -1 else { return nil }
        let realPath = String(cString: pathBuffer)
        guard realPath != base.path, pathIsContained(realPath, in: base.path) else { return nil }

        // Stat the descriptor, not the name, and take the size from the same
        // stat: an oversized file is refused without its bytes ever entering
        // the process, and a directory or a device named as a picture is
        // refused before anything tries to read one.
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maxInlineImageBytes
        else { return nil }

        // The extension is taken from where the file really is, so it describes
        // the bytes that are about to be read rather than the name that asked
        // for them.
        let format = (realPath as NSString).pathExtension.lowercased()
        guard supportedImageFileExtensions.contains(format) else { return nil }

        guard let data = Self.readAll(descriptor, upTo: Int(info.st_size)),
              data.count <= maxInlineImageBytes
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

    /// Every byte of an already-open file, or nil if the read is short or errs.
    ///
    /// `read` rather than `Data(contentsOf:)` because the whole point of the
    /// descriptor is not to name the file a second time. A short read is a
    /// refusal, not a truncated picture: the size came from `fstat` on this
    /// same descriptor a moment ago, so anything less means the file changed
    /// under the reader and what is in hand is half of two different files.
    private static func readAll(_ descriptor: Int32, upTo size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var data = Data(count: size)
        var filled = 0
        while filled < size {
            let got = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(descriptor, base + filled, size - filled)
            }
            if got > 0 { filled += got; continue }
            // 0 is end of file before the promised size; -1 with EINTR is worth
            // another turn, and any other errno is not.
            if got == 0 { return nil }
            guard errno == EINTR else { return nil }
        }
        return data
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
