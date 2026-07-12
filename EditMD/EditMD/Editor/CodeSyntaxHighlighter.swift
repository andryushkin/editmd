import AppKit
import Foundation
import Highlighter

/// Normalizes Markdown fenced-code info strings to names understood by
/// Highlight.js. The original info string is never changed or serialized back.
enum CodeLanguageRegistry {
    /// `nil` means that the author explicitly requested plain text.
    static func language(from infoString: String?) -> String? {
        guard let token = infoString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .lowercased(), !token.isEmpty else { return nil }

        switch token {
        case "text", "txt", "plaintext", "plain", "nohighlight", "no-highlight":
            return nil
        case "sh", "shell", "zsh", "console": return "bash"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "py": return "python"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "c++", "cc": return "cpp"
        case "cs", "c#": return "csharp"
        case "kt", "kts": return "kotlin"
        case "yml": return "yaml"
        case "html": return "xml"
        case "md": return "markdown"
        default: return token
        }
    }
}

/// A single Highlight.js-backed syntax highlighter used by Source, Visual and
/// Preview/PDF. It intentionally does not auto-detect unlabelled blocks.
/// Keeping the text unchanged is essential: callers only copy presentation
/// attributes into their existing NSTextStorage.
final class CodeSyntaxHighlighter: @unchecked Sendable {
    static let shared = CodeSyntaxHighlighter()
    static let maximumCodeLength = 100_000

    private let light = Highlighter()
    private let dark = Highlighter()
    private let cache = NSCache<NSString, NSAttributedString>()
    private let lock = NSLock()

    private init() {
        light?.setTheme("atom-one-light")
        dark?.setTheme("atom-one-dark")
        // Cost is the approximate UTF-16 payload, not an unbounded count of
        // potentially large code samples.
        cache.totalCostLimit = 2_000_000
    }

    /// Returns an attributed copy whose string is guaranteed to equal `code`.
    /// Unknown languages, disabled highlighting and highlighter failures fall
    /// back safely to a plain attributed string.
    func highlight(_ code: String, language infoString: String?, darkAppearance: Bool = false)
        -> NSAttributedString {
        guard !code.isEmpty,
              (code as NSString).length <= Self.maximumCodeLength,
              let language = CodeLanguageRegistry.language(from: infoString)
        else { return NSAttributedString(string: code) }

        let key = "\(darkAppearance ? "dark" : "light")\u{1F}\(language)\u{1F}\(code)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        // Highlighter owns a JavaScriptCore runtime; serialise access to each
        // instance and retain only its resulting immutable attributed string.
        lock.lock()
        let result = (darkAppearance ? dark : light)?.highlight(code, as: language)
        lock.unlock()

        guard let result, result.string == code else {
            return NSAttributedString(string: code)
        }
        let immutable = NSAttributedString(attributedString: result)
        cache.setObject(immutable, forKey: key, cost: (code as NSString).length)
        return immutable
    }

    /// Applies foreground colors only. Fonts, paragraph styles and every
    /// `md.*` attribute remain owned by the calling editor mode.
    func apply(to storage: NSTextStorage, codeRange: NSRange, language: String?,
               darkAppearance: Bool = false) {
        guard codeRange.length > 0, NSMaxRange(codeRange) <= storage.length else { return }
        let code = storage.string as NSString
        let source = code.substring(with: codeRange)
        let highlighted = highlight(source, language: language, darkAppearance: darkAppearance)
        guard highlighted.length == codeRange.length else { return }
        highlighted.enumerateAttribute(.foregroundColor,
                                       in: NSRange(location: 0, length: highlighted.length)) {
            value, range, _ in
            guard let color = value as? NSColor else { return }
            storage.addAttribute(.foregroundColor, value: color,
                                 range: NSRange(location: codeRange.location + range.location,
                                                length: range.length))
        }
    }

    /// HTML used by Preview and PDF. The highlighter's token colors are baked
    /// into safe spans, which makes the WebKit and AppKit paths deterministic
    /// without a CDN or a second JavaScript runtime.
    func html(_ code: String, language infoString: String?, darkAppearance: Bool = false) -> String {
        let highlighted = highlight(code, language: infoString, darkAppearance: darkAppearance)
        guard highlighted.string == code, highlighted.length > 0 else { return htmlEscape(code) }
        var output = ""
        highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) {
            attributes, range, _ in
            let text = (highlighted.string as NSString).substring(with: range)
            guard let color = attributes[.foregroundColor] as? NSColor else {
                output += htmlEscape(text)
                return
            }
            output += "<span class=\"hljs-token\" style=\"color: \(color.hexString)\">\(htmlEscape(text))</span>"
        }
        return output
    }

    /// Source spans include Markdown fences. Return only the code body so the
    /// opening info string and closing fence keep Markdown's muted treatment.
    func fencedBodyRange(in text: NSString, blockRange: NSRange) -> NSRange? {
        guard blockRange.length > 0, NSMaxRange(blockRange) <= text.length else { return nil }
        let openingLine = text.lineRange(for: NSRange(location: blockRange.location, length: 0))
        let opener = text.substring(with: openingLine)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = opener.first, marker == "`" || marker == "~" else { return blockRange }
        let fenceLength = opener.prefix(while: { $0 == marker }).count
        guard fenceLength >= 3 else { return blockRange }

        let blockEnd = NSMaxRange(blockRange)
        let bodyStart = min(NSMaxRange(openingLine), blockEnd)
        var location = bodyStart
        var closeStart = blockEnd
        while location < blockEnd {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let clipped = NSIntersectionRange(line, blockRange)
            let candidate = text.substring(with: clipped)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.first == marker,
               candidate.prefix(while: { $0 == marker }).count >= fenceLength,
               candidate.drop(while: { $0 == marker }).trimmingCharacters(in: .whitespaces).isEmpty {
                closeStart = clipped.location
                break
            }
            let next = NSMaxRange(line)
            if next <= location { break }
            location = next
        }
        return NSRange(location: bodyStart, length: max(0, closeStart - bodyStart))
    }

    /// Uses the app's effective appearance for native editors. HTML callers
    /// pass an explicit value because their render functions are intentionally
    /// pure and usable from tests.
    @MainActor
    func currentAppearanceIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
