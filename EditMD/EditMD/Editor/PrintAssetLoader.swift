import Foundation

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
        let base = baseDir.resolvingSymlinksInPath().standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard Self.path(resolved, isInside: base) else { return nil }

        guard supportedImageFileExtensions.contains(resolved.pathExtension.lowercased())
        else { return nil }

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
        return data
    }

    /// Whether one canonical path lies under another.
    ///
    /// Compared component by component, never as a string prefix: `/vault2`
    /// starts with the characters of `/vault` and is a different folder.
    static func path(_ url: URL, isInside base: URL) -> Bool {
        let baseComponents = base.pathComponents
        let urlComponents = url.pathComponents
        guard urlComponents.count > baseComponents.count else { return false }
        return Array(urlComponents.prefix(baseComponents.count)) == baseComponents
    }
}
