import Foundation

/// Collect frontmatter `tags` from a markdown string (first ~2KB is enough).
func frontmatterTags(in markdownPrefix: String) -> [String] {
    guard let fm = frontmatterRange(in: markdownPrefix) else { return [] }
    let body = (markdownPrefix as NSString).substring(with: fm.body)
    let props = parseFrontmatterProperties(body)
    guard let tagsProp = props.first(where: { $0.key.lowercased() == "tags" }) else {
        return []
    }
    if !tagsProp.items.isEmpty {
        return tagsProp.items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    // Scalar "a, b" fallback
    return tagsProp.value
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// Walk workspace roots, read at most `maxBytes` per file, return tag → files.
func scanWorkspaceTags(roots: [URL], maxBytes: Int = 2048) -> [String: [URL]] {
    var index: [String: [URL]] = [:]
    let mdExt: Set<String> = ["md", "markdown"]
    let fm = FileManager.default

    func walk(_ dir: URL) {
        if Task.isCancelled { return }
        let items = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in items {
            if Task.isCancelled { return }
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDir = vals?.isDirectory ?? false
            let isPackage = vals?.isPackage ?? false
            if isDir && !isPackage {
                walk(url)
            } else if mdExt.contains(url.pathExtension.lowercased()) {
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                let data = handle.readData(ofLength: maxBytes)
                // Lossy decode: the byte cap can split a multibyte character;
                // strict String(data:) would nil out and drop the whole file.
                let text = String(decoding: data, as: UTF8.self)
                for tag in frontmatterTags(in: text) {
                    index[tag, default: []].append(url.standardizedFileURL)
                }
            }
        }
    }

    for root in roots { walk(root.standardizedFileURL) }
    // Dedupe paths per tag.
    for key in index.keys {
        var seen = Set<String>()
        index[key] = index[key]?.filter { seen.insert($0.path).inserted }
    }
    return index
}
