import AppKit
import Foundation

// MARK: - Built-in plugin API

/// Metadata shown in Settings. EditMD intentionally supports only plugins
/// compiled into the app: no dynamic bundles and no downloaded executable code.
struct BuiltInPluginDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let frontmatterKey: String
}

/// A visual requested by a built-in plugin. SF Symbols stay native in Visual;
/// Preview rasterizes them into a small data URI. Emoji remain text everywhere.
enum BuiltInPluginIcon: Hashable, Sendable {
    case sfSymbol(String)
    case emoji(String)
    case text(String)
}

/// One state of a cyclic inline token. `source` is the exact markdown written
/// to disk (for example "[x]"); ordering in frontmatter defines the cycle.
struct BuiltInPluginTokenState: Hashable, Sendable {
    let source: String
    let label: String
    let icon: BuiltInPluginIcon
    let strikethrough: Bool
}

/// Semantic payload carried by Visual attributed runs / list blocks. It is
/// deliberately value-only: renderers never hold a plugin instance or closure.
struct BuiltInPluginTokenPayload: Hashable, Sendable {
    let pluginID: String
    let states: [BuiltInPluginTokenState]
    let stateIndex: Int
    /// False for a core GFM checkbox marker that is deliberately made literal
    /// because multi-checkbox owns checkbox semantics in this document.
    let isInteractive: Bool

    init(pluginID: String, states: [BuiltInPluginTokenState], stateIndex: Int,
         isInteractive: Bool = true) {
        self.pluginID = pluginID
        self.states = states
        self.stateIndex = stateIndex
        self.isInteractive = isInteractive
    }

    var state: BuiltInPluginTokenState { states[stateIndex] }

    var next: BuiltInPluginTokenPayload {
        BuiltInPluginTokenPayload(pluginID: pluginID, states: states,
                                  stateIndex: (stateIndex + 1) % states.count,
                                  isInteractive: isInteractive)
    }
}

/// One occurrence in the original markdown. Ranges are UTF-16, matching the
/// editor and WebKit bridges. A list-prefix token is presented in the list
/// marker margin; every other occurrence is an inline widget.
struct BuiltInPluginToken: Hashable, Sendable {
    let range: NSRange
    let payload: BuiltInPluginTokenPayload
    let isListMarker: Bool
}

struct BuiltInPluginActivation: Sendable {
    let descriptor: BuiltInPluginDescriptor
    let tokens: [BuiltInPluginToken]
    let ownsCoreCheckboxSyntax: Bool
    let initialChecklistPayload: BuiltInPluginTokenPayload?
}

struct BuiltInPluginSnapshot: Sendable {
    let activations: [BuiltInPluginActivation]
    let tokens: [BuiltInPluginToken]
    private let interactivePayloadBySource: [String: BuiltInPluginTokenPayload]

    init(activations: [BuiltInPluginActivation]) {
        self.activations = activations
        let sorted = activations.flatMap(\.tokens).sorted {
            $0.range.location < $1.range.location
        }
        tokens = sorted
        interactivePayloadBySource = activations.reduce(into: [:]) { result, activation in
            let template = activation.initialChecklistPayload
                ?? activation.tokens.first(where: { $0.payload.isInteractive })?.payload
            guard let template else { return }
            for (stateIndex, state) in template.states.enumerated() {
                result[state.source] = BuiltInPluginTokenPayload(
                    pluginID: template.pluginID, states: template.states,
                    stateIndex: stateIndex)
            }
        }
    }

    static let empty = BuiltInPluginSnapshot(activations: [])

    var ownsCoreCheckboxSyntax: Bool {
        activations.contains(where: \.ownsCoreCheckboxSyntax)
    }

    var initialChecklistPayload: BuiltInPluginTokenPayload? {
        activations.lazy.compactMap(\.initialChecklistPayload).first
    }

    func token(startingAt offset: Int) -> BuiltInPluginToken? {
        tokens.first { $0.range.location == offset }
    }

    func payload(matchingSource source: String) -> BuiltInPluginTokenPayload? {
        interactivePayloadBySource[source]
    }

    /// Tokens represented by U+E001 inside cmark Text nodes. Interactive list
    /// markers are normalized to `[ ]` and handled at block level; inactive
    /// core markers stay text and therefore must be restored here too.
    func textTokens(in range: NSRange) -> [BuiltInPluginToken] {
        tokens.filter {
            (!$0.isListMarker || !$0.payload.isInteractive)
                && $0.range.location >= range.location
                && NSMaxRange($0.range) <= NSMaxRange(range)
        }
    }

    /// Position-bearing candidates for an isolated Text node. The renderer's
    /// already-built Markdown AST owns code/link/image protection; custom
    /// wiki/math ranges are filtered beside that AST. No second cmark parse.
    func tokenCandidates(in source: String) -> [BuiltInPluginToken] {
        guard !interactivePayloadBySource.isEmpty else { return [] }
        let ns = source as NSString
        var result: [BuiltInPluginToken] = []
        var offset = 0
        while offset + 3 <= ns.length {
            let range = NSRange(location: offset, length: 3)
            if ns.character(at: offset) == 0x5B,
               ns.character(at: offset + 2) == 0x5D,
               let payload = interactivePayloadBySource[ns.substring(with: range)] {
                result.append(BuiltInPluginToken(range: range, payload: payload,
                                                 isListMarker: false))
                offset += 3
            } else {
                offset += 1
            }
        }
        return result
    }
}

protocol BuiltInMarkdownPlugin: Sendable {
    var descriptor: BuiltInPluginDescriptor { get }
    var ownsCoreCheckboxSyntax: Bool { get }

    /// Cheap frontmatter-only gate. It must not invoke cmark: documents that
    /// do not opt in must pay essentially zero plugin parsing cost.
    func isEnabled(in markdown: String) -> Bool

    /// Return nil when the document did not activate this plugin.
    func activate(in markdown: String, coreSpans: [Span]) -> BuiltInPluginActivation?
}

extension BuiltInMarkdownPlugin {
    var ownsCoreCheckboxSyntax: Bool { false }
}

enum BuiltInPluginRegistry {
    static let plugins: [any BuiltInMarkdownPlugin] = [MultiCheckboxPlugin()]

    static var descriptors: [BuiltInPluginDescriptor] {
        plugins.map(\.descriptor)
    }

    static func snapshot(for markdown: String, coreSpans: [Span]? = nil)
        -> BuiltInPluginSnapshot {
        snapshot(for: markdown, coreSpansProvider: {
            coreSpans ?? collectCoreSpans(markdown)
        })
    }

    static func snapshot(for markdown: String,
                         coreSpansProvider: () -> [Span]) -> BuiltInPluginSnapshot {
        guard !markdown.isEmpty else { return .empty }
        let enabled = plugins.filter { $0.isEnabled(in: markdown) }
        guard !enabled.isEmpty else { return .empty }
        let spans = coreSpansProvider()
        return BuiltInPluginSnapshot(activations: enabled.compactMap {
            $0.activate(in: markdown, coreSpans: spans)
        })
    }

    static func ownsCoreCheckboxSyntax(in markdown: String) -> Bool {
        plugins.contains {
            $0.ownsCoreCheckboxSyntax && $0.isEnabled(in: markdown)
        }
    }

    /// Cycles the token that still starts at `offset`. Verifying the current
    /// source makes delayed Preview messages harmless after intervening edits.
    static func cycleToken(in markdown: String, at offset: Int) -> String? {
        let snapshot = snapshot(for: markdown)
        guard let token = snapshot.token(startingAt: offset),
              token.payload.isInteractive else { return nil }
        let ns = markdown as NSString
        guard NSMaxRange(token.range) <= ns.length,
              ns.substring(with: token.range) == token.payload.state.source else { return nil }
        return ns.replacingCharacters(in: token.range, with: token.payload.next.state.source)
    }
}

// Private-use sentinel used only in a layout-preserving parse copy. It never
// reaches the attributed model, HTML, or the saved markdown.
let builtInPluginSentinelUnit: unichar = 0xE001
private let builtInPluginSentinel = "\u{E001}"

/// Document-order cursor for U+E001 runs. Exact offsets remain authoritative;
/// nil offsets use the next token only as a visible fail-safe. Each token is
/// considered once, so Preview hydration stays O(n).
struct BuiltInPluginSentinelCursor {
    private let tokens: [BuiltInPluginToken]
    private var index = 0

    init(tokens: [BuiltInPluginToken]) {
        self.tokens = tokens.filter {
            !$0.isListMarker || !$0.payload.isInteractive
        }
    }

    mutating func next(startingAt offset: Int?, maxLength: Int) -> BuiltInPluginToken? {
        if let offset {
            while index < tokens.count, tokens[index].range.location < offset {
                index += 1
            }
            guard index < tokens.count, tokens[index].range.location == offset else {
                return nil
            }
        }
        guard index < tokens.count, tokens[index].range.length <= maxLength else {
            return nil
        }
        let token = tokens[index]
        index += 1
        return token
    }
}

/// Makes arbitrary inline `[marker]` tokens opaque to cmark while normalizing
/// list-prefix tokens to `[ ]`, so cmark still builds a task-list node. Every
/// replacement has the same UTF-16 length as its source range.
func maskBuiltInPluginTokensForParsing(_ source: String,
                                       snapshot: BuiltInPluginSnapshot,
                                       sourceOffset: Int = 0) -> String {
    guard !snapshot.tokens.isEmpty else { return source }
    let mutable = NSMutableString(string: source)
    let localLength = mutable.length
    for token in snapshot.tokens.reversed() {
        let local = NSRange(location: token.range.location - sourceOffset,
                            length: token.range.length)
        guard local.location >= 0, NSMaxRange(local) <= localLength else { continue }
        let replacement = token.isListMarker && token.payload.isInteractive
            ? "[ ]"
            : String(repeating: builtInPluginSentinel, count: local.length)
        guard (replacement as NSString).length == local.length else { continue }
        mutable.replaceCharacters(in: local, with: replacement)
    }
    return mutable as String
}

/// Shared attributed representation for Visual and large-table drawing.
func builtInPluginTokenAttributedString(_ payload: BuiltInPluginTokenPayload,
                                        font: NSFont,
                                        textColor: NSColor,
                                        attributes: [NSAttributedString.Key: Any] = [:])
    -> NSAttributedString {
    var attrs = attributes
    // An in-place cycle may reuse an SF Symbol run's attributes. Do not carry
    // its old attachment or completed-state strike into the next state.
    attrs.removeValue(forKey: .attachment)
    attrs.removeValue(forKey: .strikethroughStyle)
    attrs[.font] = font
    attrs[.foregroundColor] = textColor
    // Inactive core checkboxes still need a semantic run so serialization
    // writes their exact `[ ]` / `[x]` source instead of Markdown-escaping it.
    // Hit testing checks `isInteractive` before offering a cycle action.
    attrs[.mdBuiltInPluginToken] = payload
    if payload.state.strikethrough {
        attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }

    switch payload.state.icon {
    case .emoji(let emoji), .text(let emoji):
        return NSAttributedString(string: emoji, attributes: attrs)
    case .sfSymbol(let name):
        guard let image = NSImage(systemSymbolName: name,
                                  accessibilityDescription: payload.state.label) else {
            return NSAttributedString(string: payload.state.source, attributes: attrs)
        }
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        let configured = image.withSymbolConfiguration(config) ?? image
        configured.isTemplate = true
        let attachment = NSTextAttachment()
        attachment.image = configured
        let side = ceil(font.ascender - font.descender)
        attachment.bounds = NSRect(x: 0, y: floor(font.descender / 2), width: side, height: side)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attrs, range: NSRange(location: 0, length: result.length))
        return result
    }
}

func builtInPluginTokenHTML(_ payload: BuiltInPluginTokenPayload,
                            sourceOffset: Int) -> String {
    guard payload.isInteractive else {
        return "<span data-md-lo=\"\(sourceOffset)\" "
            + "data-md-hi=\"\(sourceOffset + (payload.state.source as NSString).length)\">"
            + htmlEscape(payload.state.source) + "</span>"
    }
    let iconHTML: String
    switch payload.state.icon {
    case .emoji(let value), .text(let value):
        iconHTML = "<span aria-hidden=\"true\">\(htmlEscape(value))</span>"
    case .sfSymbol(let name):
        if let uri = sfSymbolPNGDataURI(name: name, label: payload.state.label) {
            iconHTML = "<img class=\"multi-checkbox-sf\" src=\"\(uri)\" alt=\"\">"
        } else {
            iconHTML = "<span aria-hidden=\"true\">\(htmlEscape(payload.state.source))</span>"
        }
    }
    let label = htmlAttributeEscape("Change status. Current: \(payload.state.label)")
    let strike = payload.state.strikethrough ? " data-strike=\"true\"" : ""
    return "<button type=\"button\" class=\"multi-checkbox\" "
        + "data-plugin-offset=\"\(sourceOffset)\" aria-label=\"\(label)\" "
        + "title=\"\(label)\"\(strike)>\(iconHTML)</button>"
}

private func sfSymbolPNGDataURI(name: String, label: String) -> String? {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: label) else {
        return nil
    }
    let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
    let rendered = image.withSymbolConfiguration(config) ?? image
    guard let tiff = rendered.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
    return "data:image/png;base64,\(png.base64EncodedString())"
}

// MARK: - Multi-checkbox plugin

struct MultiCheckboxConfiguration: Hashable, Sendable {
    let states: [BuiltInPluginTokenState]
}

struct MultiCheckboxPlugin: BuiltInMarkdownPlugin {
    static let pluginID = "multi-checkbox"

    let descriptor = BuiltInPluginDescriptor(
        id: pluginID,
        name: "Multi-checkbox",
        summary: "Cycles custom [marker] states declared in a document's frontmatter.",
        frontmatterKey: "editmd.plugins.multi-checkbox")

    let ownsCoreCheckboxSyntax = true

    func isEnabled(in markdown: String) -> Bool {
        Self.configuration(in: markdown) != nil
    }

    func activate(in markdown: String, coreSpans: [Span]) -> BuiltInPluginActivation? {
        guard let configuration = Self.configuration(in: markdown) else { return nil }
        let tokens = Self.scanTokens(in: markdown, configuration: configuration,
                                     coreSpans: coreSpans)
        let initial = BuiltInPluginTokenPayload(pluginID: Self.pluginID,
                                                states: configuration.states,
                                                stateIndex: 0)
        return BuiltInPluginActivation(descriptor: descriptor, tokens: tokens,
                                       ownsCoreCheckboxSyntax: true,
                                       initialChecklistPayload: initial)
    }

    /// Parses only this built-in plugin's schema. It is intentionally not a
    /// general YAML implementation: built-in plugins are versioned with EditMD,
    /// and the existing frontmatter display parser remains lightweight.
    static func configuration(in markdown: String) -> MultiCheckboxConfiguration? {
        guard let fm = frontmatterRange(in: markdown) else { return nil }
        let body = (markdown as NSString).substring(with: fm.body)
        let lines = body.components(separatedBy: "\n").map(PluginYAMLLine.init)

        guard let editmd = child(named: "editmd", after: -1, parentIndent: -1, in: lines),
              let plugins = child(named: "plugins", after: editmd.index,
                                  parentIndent: editmd.indent, in: lines),
              let plugin = child(named: pluginID, after: plugins.index,
                                 parentIndent: plugins.indent, in: lines),
              let statesNode = child(named: "states", after: plugin.index,
                                     parentIndent: plugin.indent, in: lines)
        else { return nil }

        var rawStates: [[String: String]] = []
        var current: [String: String]?
        var sequenceIndent: Int?
        var index = statesNode.index + 1
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard !line.content.isEmpty else { continue }
            let isItem = line.content.hasPrefix("- ") || line.content == "-"
            if sequenceIndent == nil {
                guard isItem, line.indent >= statesNode.indent else { break }
                sequenceIndent = line.indent
            }
            guard let sequenceIndent else { break }
            if line.indent < sequenceIndent { break }

            if line.indent == sequenceIndent, isItem {
                if let current { rawStates.append(current) }
                current = [:]
                let remainder = line.content == "-" ? "" : String(line.content.dropFirst(2))
                if let (key, value) = yamlPair(remainder) { current?[key] = value }
            } else if var state = current, line.indent > sequenceIndent,
                      let (key, value) = yamlPair(line.content) {
                state[key] = value
                current = state
            } else if line.indent == sequenceIndent {
                break
            }
        }
        if let current { rawStates.append(current) }

        var states: [BuiltInPluginTokenState] = []
        var markers = Set<String>()
        for raw in rawStates {
            guard let marker = raw["marker"], (marker as NSString).length == 1,
                  marker != "[", marker != "]", markers.insert(marker).inserted
            else { continue }
            let label = raw["label"].flatMap { $0.isEmpty ? nil : $0 } ?? marker
            let icon = parseIcon(raw["icon"] ?? marker)
            let strike = parseYAMLBool(raw["strikethrough"]) ?? false
            states.append(BuiltInPluginTokenState(source: "[\(marker)]", label: label,
                                                  icon: icon, strikethrough: strike))
        }
        guard states.count >= 2 else { return nil }
        return MultiCheckboxConfiguration(states: states)
    }

    static func scanTokens(in markdown: String,
                           configuration: MultiCheckboxConfiguration,
                           coreSpans: [Span]? = nil) -> [BuiltInPluginToken] {
        let ns = markdown as NSString
        let spans = coreSpans ?? collectCoreSpans(markdown)
        var protected = spans.compactMap { span -> NSRange? in
            switch span.kind {
            case .code, .codeMarker, .codeBlockBody, .codeBlockFence,
                 .linkText, .linkSyntax, .imageText, .imageSyntax,
                 .htmlInline, .htmlBlock, .wikiLink, .wikiLinkSyntax,
                 .mathBody, .mathMarker:
                return span.range
            default:
                return nil
            }
        }
        if let fm = frontmatterRange(in: markdown) { protected.append(fm.full) }

        let stateBySource = Dictionary(uniqueKeysWithValues:
            configuration.states.enumerated().map { ($0.element.source, $0.offset) })
        let payloadStates = configuration.states
        var result: [BuiltInPluginToken] = []
        var location = 0
        while location + 3 <= ns.length {
            let candidate = NSRange(location: location, length: 3)
            defer { location += 1 }
            guard ns.character(at: location) == 0x5B,
                  ns.character(at: location + 2) == 0x5D else { continue }
            let source = ns.substring(with: candidate)
            let listMarker = isListMarker(candidate, in: ns)
            let stateIndex = stateBySource[source]
            let disabledCoreMarker = listMarker && stateIndex == nil
                && (source == "[ ]" || source == "[x]" || source == "[X]")
            guard stateIndex != nil || disabledCoreMarker,
                  !protected.contains(where: { NSIntersectionRange($0, candidate).length > 0 })
            else { continue }

            // Markdown links/images/reference labels keep their native meaning.
            if location > 0, ns.character(at: location - 1) == 0x21 { continue } // ![x]
            if NSMaxRange(candidate) < ns.length {
                let next = ns.character(at: NSMaxRange(candidate))
                if next == 0x28 || next == 0x5B || next == 0x3A { continue } // (, [, :
            }

            let payload: BuiltInPluginTokenPayload
            if let stateIndex {
                payload = BuiltInPluginTokenPayload(pluginID: pluginID,
                                                    states: payloadStates,
                                                    stateIndex: stateIndex)
            } else {
                let state = BuiltInPluginTokenState(
                    source: source, label: "Inactive checkbox marker",
                    icon: .text(source), strikethrough: false)
                payload = BuiltInPluginTokenPayload(pluginID: pluginID, states: [state],
                                                    stateIndex: 0, isInteractive: false)
            }
            result.append(BuiltInPluginToken(range: candidate, payload: payload,
                                             isListMarker: listMarker))
            location += 2
        }
        return result
    }

    private static func isListMarker(_ token: NSRange, in source: NSString) -> Bool {
        let line = source.lineRange(for: NSRange(location: token.location, length: 0))
        let prefixRange = NSRange(location: line.location, length: token.location - line.location)
        let prefix = source.substring(with: prefixRange)
        return prefix.range(
            of: #"^[ \t]*(?:>[ \t]*)*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+$"#,
            options: .regularExpression) != nil
    }

    private static func parseIcon(_ raw: String) -> BuiltInPluginIcon {
        if raw.hasPrefix("sf:") {
            let name = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? .text("□") : .sfSymbol(name)
        }
        if raw.hasPrefix("emoji:") {
            let emoji = String(raw.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return .emoji(emoji.isEmpty ? "□" : emoji)
        }
        return .text(raw)
    }
}

// MARK: - Tiny ordered YAML subset for plugin configuration

private struct PluginYAMLLine {
    let indent: Int
    let content: String

    init(_ raw: String) {
        indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) {
            $0 + ($1 == "\t" ? 4 : 1)
        }
        content = stripYAMLComment(
            String(raw.drop(while: { $0 == " " || $0 == "\t" })))
            .trimmingCharacters(in: .whitespaces)
    }
}

private func child(named name: String, after start: Int, parentIndent: Int,
                   in lines: [PluginYAMLLine]) -> (index: Int, indent: Int)? {
    var index = start + 1
    var directIndent: Int?
    while index < lines.count {
        let line = lines[index]
        if !line.content.isEmpty {
            if start >= 0, line.indent <= parentIndent { return nil }
            if directIndent == nil { directIndent = line.indent }
            if line.indent == directIndent, line.content == "\(name):" {
                return (index, line.indent)
            }
        }
        index += 1
    }
    return nil
}

private func yamlPair(_ content: String) -> (String, String)? {
    guard let colon = content.firstIndex(of: ":") else { return nil }
    let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    let value = String(content[content.index(after: colon)...])
        .trimmingCharacters(in: .whitespaces)
    return (key, unquotePluginYAML(value))
}

private func unquotePluginYAML(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, let last = value.last,
          (first == "\"" && last == "\"") || (first == "'" && last == "'")
    else { return value }
    let inner = String(value.dropFirst().dropLast())
    return first == "\""
        ? inner.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        : inner.replacingOccurrences(of: "''", with: "'")
}

private func parseYAMLBool(_ value: String?) -> Bool? {
    switch value?.lowercased() {
    case "true", "yes", "on": return true
    case "false", "no", "off": return false
    default: return nil
    }
}

private func stripYAMLComment(_ line: String) -> String {
    var single = false
    var double = false
    var escaped = false
    for index in line.indices {
        let char = line[index]
        if escaped { escaped = false; continue }
        if char == "\\", double { escaped = true; continue }
        if char == "'", !double { single.toggle(); continue }
        if char == "\"", !single { double.toggle(); continue }
        if char == "#", !single, !double,
           (index == line.startIndex || line[line.index(before: index)].isWhitespace) {
            return String(line[..<index])
        }
    }
    return line
}
