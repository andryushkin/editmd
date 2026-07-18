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

extension Notification.Name {
    /// A background highlight finished and its runs are in the cache. Source and
    /// Visual re-run their (cheap, cache-hit) paint pass on it.
    static let codeHighlightingDidWarm = Notification.Name("EditMDCodeHighlightingDidWarm")
}

/// One colored token: both palettes at once, so a single pass serves the light
/// and the dark appearance without re-running Highlight.js.
struct CodeTokenRun {
    let range: NSRange
    /// Resolves per drawing appearance — a system appearance switch or the app's
    /// own Light/Dark override repaints without a rehighlight.
    let color: NSColor
    let lightHex: String
    let darkHex: String
}

/// A single Highlight.js-backed syntax highlighter used by Source, Visual and
/// Preview/PDF. It intentionally does not auto-detect unlabelled blocks.
/// Keeping the text unchanged is essential: callers only copy presentation
/// attributes into their existing NSTextStorage.
final class CodeSyntaxHighlighter: @unchecked Sendable {
    static let shared = CodeSyntaxHighlighter()
    /// Highlight.js has regex-heavy worst cases that can keep JavaScriptCore and
    /// its parallel GC workers busy for seconds. Large blocks stay readable as
    /// plain code instead of turning a presentation-only feature into sustained
    /// multi-core work.
    static let maximumCodeLength = 8_192
    /// Highlight.js is expensive — measured on this project's own test host, one
    /// pass over both palettes costs ~4 ms at 256 chars, ~18 ms at 1 KB and
    /// ~58 ms at 4 KB. So only a tiny snippet runs inline (it paints on the very
    /// first pass, no flash); everything else warms off the main thread and
    /// repaints via `.codeHighlightingDidWarm`, and typing never waits on JS.
    static let inlineLimit = 256
    /// The serial worker stays bounded when typing produces obsolete keys, while
    /// a normal document can warm several blocks before asking the editors for
    /// one consolidated repaint.
    private static let maxWarmsInFlight = 8
    /// Cap on remembered previous runs (one per code block of the open files).
    private static let maxStaleKeys = 256

    private final class CachedRuns {
        let runs: [CodeTokenRun]
        init(_ runs: [CodeTokenRun]) { self.runs = runs }
    }

    private let light = Highlighter()
    private let dark = Highlighter()
    private let cache = NSCache<NSString, CachedRuns>()
    /// Serializes the two JavaScriptCore runtimes (each Highlighter owns one).
    private let lock = NSLock()
    private let warmQueue = DispatchQueue(label: "com.editmd.code-highlight", qos: .userInitiated)
    /// Keys currently being highlighted off main; guarded by `lock`.
    private var warmsInFlight: Set<String> = []
    /// Last known runs per code block (stale-while-revalidate): while a block
    /// warms, its previous colors keep showing instead of dropping to plain —
    /// otherwise every keystroke inside a code block would flash it grey.
    /// Guarded by `lock`.
    private var staleRuns: [String: [CodeTokenRun]] = [:]

    private init() {
        light?.setTheme("atom-one-light")
        dark?.setTheme("atom-one-dark")
        // Cost is the approximate UTF-16 payload, not an unbounded count of
        // potentially large code samples.
        cache.totalCostLimit = 2_000_000
    }

    // MARK: - Token runs

    /// Token runs for `code`, or `nil` when the answer isn't ready yet (a big
    /// block warming off main). An empty array is a definitive "nothing to
    /// paint" (plain text, unknown language, highlighter failure) and is cached,
    /// so a caller never spins on a block that can't be highlighted.
    func tokenRuns(for code: String, language infoString: String?,
                   blocking: Bool = false) -> [CodeTokenRun]? {
        guard !code.isEmpty,
              (code as NSString).length <= Self.maximumCodeLength,
              let language = CodeLanguageRegistry.language(from: infoString)
        else { return [] }

        let key = "\(language)\u{1F}\(code)"
        if let cached = cache.object(forKey: key as NSString) { return cached.runs }
        if blocking || (code as NSString).length <= Self.inlineLimit {
            return compute(code, language: language, key: key)
        }
        scheduleWarm(code, language: language, key: key)
        return nil
    }

    @discardableResult
    private func compute(_ code: String, language: String, key: String) -> [CodeTokenRun] {
        lock.lock()
        let lightRun = light?.highlight(code, as: language)
        let darkRun = dark?.highlight(code, as: language)
        lock.unlock()

        var runs: [CodeTokenRun] = []
        // Highlight.js must not have touched the text: callers paint attributes
        // over their own storage, so any length drift would smear the colors.
        if let lightRun, let darkRun, lightRun.string == code, darkRun.string == code {
            runs = mergeRuns(light: lightRun, dark: darkRun)
        }
        cache.setObject(CachedRuns(runs), forKey: key as NSString,
                        cost: max(1, (code as NSString).length))
        return runs
    }

    /// Walks both palettes in lockstep and cuts a run wherever either changes
    /// color — the two runs cover the same text, so the split points just merge.
    private func mergeRuns(light: NSAttributedString, dark: NSAttributedString) -> [CodeTokenRun] {
        let full = NSRange(location: 0, length: light.length)
        var lightRuns: [(NSRange, NSColor?)] = []
        var darkRuns: [(NSRange, NSColor?)] = []
        light.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            lightRuns.append((range, value as? NSColor))
        }
        dark.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            darkRuns.append((range, value as? NSColor))
        }

        var runs: [CodeTokenRun] = []
        var position = 0
        var l = 0
        var d = 0
        while position < full.length, l < lightRuns.count, d < darkRuns.count {
            let lightEnd = NSMaxRange(lightRuns[l].0)
            let darkEnd = NSMaxRange(darkRuns[d].0)
            let end = min(lightEnd, darkEnd)
            if let lightColor = lightRuns[l].1, let darkColor = darkRuns[d].1, end > position {
                runs.append(CodeTokenRun(
                    range: NSRange(location: position, length: end - position),
                    color: Self.dynamicColor(light: lightColor, dark: darkColor),
                    lightHex: lightColor.hexString,
                    darkHex: darkColor.hexString))
            }
            position = end
            if lightEnd == end { l += 1 }
            if darkEnd == end { d += 1 }
        }
        return runs
    }

    private func scheduleWarm(_ code: String, language: String, key: String) {
        lock.lock()
        let skip = warmsInFlight.contains(key) || warmsInFlight.count >= Self.maxWarmsInFlight
        if !skip { warmsInFlight.insert(key) }
        lock.unlock()
        // Dropped requests are not lost: every finished warm posts a repaint, the
        // repaint asks again, and a still-uncached block re-queues then.
        guard !skip else { return }

        warmQueue.async { [weak self] in
            guard let self else { return }
            self.compute(code, language: language, key: key)
            self.lock.lock()
            self.warmsInFlight.remove(key)
            let batchFinished = self.warmsInFlight.isEmpty
            self.lock.unlock()
            guard batchFinished else { return }
            DispatchQueue.main.async {
                // A new batch may have started while this main-queue hop was
                // pending. Its own final job will request the repaint.
                self.lock.lock()
                let stillFinished = self.warmsInFlight.isEmpty
                self.lock.unlock()
                guard stillFinished else { return }
                NotificationCenter.default.post(name: .codeHighlightingDidWarm, object: self)
            }
        }
    }

    /// A color that follows the *drawing* appearance instead of a snapshot of
    /// it, so `general.appearance` (☀/🌙) and system Dark Mode both land without
    /// re-running the highlighter. The provider captures plain components —
    /// NSColor is not Sendable.
    private static func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
        let l = light.srgbComponents
        let d = dark.srgbComponents
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? d : l
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
    }

    // MARK: - Editor surfaces

    /// What to paint right now for a block: its fresh runs, or — while a big
    /// block warms off main — the last runs seen under `stableKey` (a block
    /// identity, e.g. the file path plus the block's index). Runs that no longer
    /// fit the edited text are dropped by the callers' bounds check.
    func runsToPaint(for code: String, language: String?, stableKey: String?,
                     blocking: Bool = false) -> [CodeTokenRun] {
        if let fresh = tokenRuns(for: code, language: language, blocking: blocking) {
            if let stableKey { rememberStale(fresh, for: stableKey) }
            return fresh
        }
        guard let stableKey else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return staleRuns[stableKey] ?? []
    }

    private func rememberStale(_ runs: [CodeTokenRun], for key: String) {
        lock.lock()
        if staleRuns.count > Self.maxStaleKeys { staleRuns.removeAll() }
        staleRuns[key] = runs
        lock.unlock()
    }

    /// Applies foreground colors only. Fonts, paragraph styles and every `md.*`
    /// attribute remain owned by the calling editor mode.
    func apply(to storage: NSTextStorage, codeRange: NSRange, language: String?,
               stableKey: String? = nil, blocking: Bool = false) {
        guard codeRange.length > 0, NSMaxRange(codeRange) <= storage.length else { return }
        let source = (storage.string as NSString).substring(with: codeRange)
        let runs = runsToPaint(for: source, language: language, stableKey: stableKey,
                               blocking: blocking)
        for run in runs where NSMaxRange(run.range) <= codeRange.length {
            storage.addAttribute(.foregroundColor, value: run.color,
                                 range: NSRange(location: codeRange.location + run.range.location,
                                                length: run.range.length))
        }
    }

    /// HTML for Preview and PDF. Each token carries BOTH palettes as custom
    /// properties (`--tl` / `--td`); the page's CSS picks one by
    /// `prefers-color-scheme`, so a theme switch needs no re-render and the page
    /// is never light-on-dark. Rendering is always synchronous — the HTML string
    /// has no second chance to repaint.
    ///
    /// With `lineRanges` (the SOURCE range of each code line) every line is also
    /// wrapped in its own `data-md-lo/hi` span, giving split-scroll sync an
    /// anchor per line. Token runs are cut at the line boundaries they cross.
    func html(_ code: String, language infoString: String?,
              lineRanges: [NSRange]? = nil) -> String {
        let runs = tokenRuns(for: code, language: infoString, blocking: true) ?? []
        let ns = code as NSString

        func tokenized(_ range: NSRange) -> String {
            guard !runs.isEmpty else { return htmlEscape(ns.substring(with: range)) }
            var output = ""
            var cursor = range.location
            for run in runs {
                let hit = NSIntersectionRange(run.range, range)
                guard hit.length > 0, hit.location >= cursor else { continue }
                if hit.location > cursor {
                    output += htmlEscape(ns.substring(
                        with: NSRange(location: cursor, length: hit.location - cursor)))
                }
                output += "<span class=\"hljs-token\" "
                    + "style=\"--tl:\(run.lightHex);--td:\(run.darkHex)\">"
                    + htmlEscape(ns.substring(with: hit)) + "</span>"
                cursor = NSMaxRange(hit)
            }
            if cursor < NSMaxRange(range) {
                output += htmlEscape(ns.substring(
                    with: NSRange(location: cursor, length: NSMaxRange(range) - cursor)))
            }
            return output
        }

        guard let lineRanges else { return tokenized(NSRange(location: 0, length: ns.length)) }

        var output = ""
        var lineStart = 0
        var line = 0
        while lineStart <= ns.length {
            let newline = ns.range(of: "\n", options: [],
                                   range: NSRange(location: lineStart,
                                                  length: ns.length - lineStart))
            let end = newline.location == NSNotFound ? ns.length : newline.location
            let body = NSRange(location: lineStart, length: end - lineStart)
            if line < lineRanges.count {
                let source = lineRanges[line]
                output += "<span class=\"cl\" data-md-lo=\"\(source.location)\""
                    + " data-md-hi=\"\(NSMaxRange(source))\">"
                    + tokenized(body) + "</span>"
            } else {
                output += tokenized(body)
            }
            if newline.location == NSNotFound { break }
            output += "\n"           // outside the span: it is not part of the line
            lineStart = end + 1
            line += 1
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

    /// CSS that binds the token spans to the page's appearance. Kept next to the
    /// span emitter so the two custom-property names can't drift apart.
    static let tokenCSS = """
        .hljs-token { color: var(--tl); }
        @media (prefers-color-scheme: dark) {
            .hljs-token { color: var(--td); }
        }
        """
}

private extension NSColor {
    /// sRGB components, safe to capture in a Sendable closure.
    var srgbComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        guard let rgb = usingColorSpace(.sRGB) else { return (0, 0, 0, 1) }
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }
}
