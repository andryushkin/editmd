import Foundation

/// Bundled KaTeX distribution (`Resources/katex/`): minified JS plus CSS with
/// the woff2 fonts already inlined as data: URIs — the preview page loads via
/// `loadHTMLString(baseURL: nil)`, so no external file may be referenced.
/// Loaded once per process; empty strings when the bundle files are missing
/// (the preview then shows raw TeX — graceful degradation, no crash).
enum KaTeXResources {
    static let css: String = load("katex", ext: "css")
    /// `</script` is neutralized so embedding the JS inline can never
    /// terminate its own <script> element early.
    static let js: String = load("katex", ext: "js")
        .replacingOccurrences(of: "</script", with: "<\\/script")

    static var isAvailable: Bool { !css.isEmpty && !js.isEmpty }

    private static func load(_ name: String, ext: String) -> String {
        // xcodegen flattens the Resources tree into the bundle root, but keep
        // the subdirectory probe in case the project moves to folder refs.
        let url = Bundle.main.url(forResource: name, withExtension: ext,
                                  subdirectory: "katex")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
        guard let url, let s = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return s
    }
}
