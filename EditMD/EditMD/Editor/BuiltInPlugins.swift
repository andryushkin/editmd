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

enum BuiltInPluginConfigurationField: String, Sendable {
    case marker
    case label
    case icon
    case strikethrough
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

    /// A configured one-state token is still a real plugin token and keeps its
    /// icon, but presenting it as clickable would promise a change that cannot
    /// happen. `isInteractive` distinguishes plugin-owned tokens from literal
    /// core checkbox syntax; `canCycle` is the user-action capability.
    var canCycle: Bool { isInteractive && states.count > 1 }

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

struct BuiltInPluginConfigurationDiagnostic: Hashable, Sendable {
    let descriptor: BuiltInPluginDescriptor
    let message: String
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

    /// Maps candidates from cmark's unescaped Text value back to the raw Text
    /// source. Escaped forms such as `\[?\]` still appear as `[?]` in
    /// `Text.string`, but are not semantic plugin tokens in Source/Preview.
    func tokenCandidates(in displaySource: String,
                         matching source: String) -> [BuiltInPluginToken] {
        let displayed = tokenCandidates(in: displaySource)
        guard !displayed.isEmpty, displaySource != source else { return displayed }

        let sourceOccurrences = configuredMarkerOccurrences(in: source)
        var displayIndex = 0
        var result: [BuiltInPluginToken] = []
        for occurrence in sourceOccurrences {
            while displayIndex < displayed.count,
                  displayed[displayIndex].payload.state.source != occurrence.source {
                displayIndex += 1
            }
            guard displayIndex < displayed.count else { break }
            if occurrence.isExactSourceToken {
                result.append(displayed[displayIndex])
            }
            displayIndex += 1
        }
        return result
    }

    private func configuredMarkerOccurrences(in source: String)
        -> [(source: String, isExactSourceToken: Bool)] {
        guard !interactivePayloadBySource.isEmpty else { return [] }
        let ns = source as NSString
        var result: [(String, Bool)] = []
        var offset = 0
        while offset < ns.length {
            guard ns.character(at: offset) == 0x5B else {
                offset += 1
                continue
            }

            // Common and semantically active form: exact three UTF-16 units.
            if offset + 3 <= ns.length {
                let exactRange = NSRange(location: offset, length: 3)
                let exact = ns.substring(with: exactRange)
                if interactivePayloadBySource[exact] != nil {
                    result.append((exact, true))
                    offset += 3
                    continue
                }
            }

            // cmark can unescape the marker or closing bracket. Record that
            // displayed occurrence for alignment, but never make it a widget.
            var markerLocation = offset + 1
            var markerEscaped = false
            if markerLocation < ns.length, ns.character(at: markerLocation) == 0x5C {
                markerEscaped = true
                markerLocation += 1
            }
            guard markerLocation < ns.length else { offset += 1; continue }
            let marker = ns.substring(
                with: NSRange(location: markerLocation, length: 1))

            var closingLocation = markerLocation + 1
            var closingEscaped = false
            if closingLocation < ns.length, ns.character(at: closingLocation) == 0x5C {
                closingEscaped = true
                closingLocation += 1
            }
            guard closingLocation < ns.length,
                  ns.character(at: closingLocation) == 0x5D else {
                offset += 1
                continue
            }
            let normalized = "[\(marker)]"
            if interactivePayloadBySource[normalized] != nil {
                result.append((normalized, !markerEscaped && !closingEscaped))
            }
            offset = closingLocation + 1
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

    /// Declaration presence is separate from activation: an invalid block must
    /// not make the Add menu insert a second copy of the same plugin.
    func isDeclared(in markdown: String) -> Bool

    /// A declared but invalid plugin remains visible in Preview instead of
    /// silently disappearing while the Add menu still calls it installed.
    func configurationIssue(in markdown: String) -> String?

    /// Adds the plugin's smallest valid document-scoped configuration.
    func installingDefaultConfiguration(in markdown: String) -> String?

    /// Appends one default configuration row when the plugin supports it.
    func addingConfigurationState(in markdown: String) -> String?

    /// Return nil when the document did not activate this plugin.
    func activate(in markdown: String, coreSpans: [Span]) -> BuiltInPluginActivation?

    /// Frontmatter-declared checklist states for plugins that define a cyclic
    /// checklist. Must stay frontmatter-only (no cmark): the Properties panel
    /// reads it on every SwiftUI update of the inspector.
    func checklistStates(in markdown: String) -> [BuiltInPluginTokenState]?
}

extension BuiltInMarkdownPlugin {
    var ownsCoreCheckboxSyntax: Bool { false }
    func isDeclared(in markdown: String) -> Bool { isEnabled(in: markdown) }
    func configurationIssue(in markdown: String) -> String? { nil }
    func installingDefaultConfiguration(in markdown: String) -> String? { nil }
    func addingConfigurationState(in markdown: String) -> String? { nil }
    func checklistStates(in markdown: String) -> [BuiltInPluginTokenState]? { nil }
}

/// One active plugin's settings card in the Properties inspector.
struct BuiltInPluginChecklistCard {
    let descriptor: BuiltInPluginDescriptor
    let states: [BuiltInPluginTokenState]
}

enum BuiltInPluginRegistry {
    static let plugins: [any BuiltInMarkdownPlugin] = [MultiCheckboxPlugin()]

    static var descriptors: [BuiltInPluginDescriptor] {
        plugins.map(\.descriptor)
    }

    static func declaredPluginIDs(in markdown: String) -> Set<String> {
        Set(plugins.lazy.filter { $0.isDeclared(in: markdown) }.map { $0.descriptor.id })
    }

    static func configurationDiagnostics(in markdown: String)
        -> [BuiltInPluginConfigurationDiagnostic] {
        plugins.compactMap { plugin in
            guard let message = plugin.configurationIssue(in: markdown) else { return nil }
            return BuiltInPluginConfigurationDiagnostic(
                descriptor: plugin.descriptor, message: message)
        }
    }

    /// Settings cards for the Properties inspector. Frontmatter-only — no
    /// token scan, cheap enough for per-keystroke SwiftUI recomputes.
    static func checklistCards(in markdown: String) -> [BuiltInPluginChecklistCard] {
        plugins.compactMap { plugin in
            guard let states = plugin.checklistStates(in: markdown) else { return nil }
            return BuiltInPluginChecklistCard(descriptor: plugin.descriptor,
                                              states: states)
        }
    }

    static func installPlugin(id: String, in markdown: String) -> String? {
        plugins.first { $0.descriptor.id == id }?
            .installingDefaultConfiguration(in: markdown)
    }

    static func addConfigurationState(pluginID: String, in markdown: String) -> String? {
        plugins.first { $0.descriptor.id == pluginID }?
            .addingConfigurationState(in: markdown)
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
              token.payload.canCycle else { return nil }
        let ns = markdown as NSString
        guard NSMaxRange(token.range) <= ns.length,
              ns.substring(with: token.range) == token.payload.state.source else { return nil }
        return ns.replacingCharacters(in: token.range, with: token.payload.next.state.source)
    }

    /// Applies a settings edit from Preview through a registry-owned whitelist.
    /// Web content never supplies a source range or arbitrary YAML path.
    static func updateConfiguration(in markdown: String, pluginID: String,
                                    stateIndex: Int,
                                    field: BuiltInPluginConfigurationField,
                                    value: String,
                                    expectedSource: String? = nil) -> String? {
        guard pluginID == MultiCheckboxPlugin.pluginID else { return nil }
        return MultiCheckboxPlugin.updateConfiguration(
            in: markdown, stateIndex: stateIndex, field: field, value: value,
            expectedSource: expectedSource)
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

/// Presentation-only icon used by token widgets and the read-only frontmatter
/// legend. Semantic token ownership is added by the caller when appropriate.
func builtInPluginIconAttributedString(_ icon: BuiltInPluginIcon,
                                       label: String,
                                       fallback: String,
                                       font: NSFont,
                                       textColor: NSColor,
                                       attributes: [NSAttributedString.Key: Any] = [:])
    -> NSAttributedString {
    var attrs = attributes
    attrs.removeValue(forKey: .attachment)
    attrs[.font] = font
    attrs[.foregroundColor] = textColor

    switch icon {
    case .emoji(let emoji), .text(let emoji):
        return NSAttributedString(string: emoji, attributes: attrs)
    case .sfSymbol(let name):
        guard let image = NSImage(systemSymbolName: name,
                                  accessibilityDescription: label) else {
            return NSAttributedString(string: fallback, attributes: attrs)
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

/// Shared semantic token representation for Visual and large-table drawing.
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
    // Inactive core checkboxes still need a semantic run so serialization
    // writes their exact `[ ]` / `[x]` source instead of Markdown-escaping it.
    // Hit testing checks `isInteractive` before offering a cycle action.
    attrs[.mdBuiltInPluginToken] = payload
    if payload.state.strikethrough {
        attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    return builtInPluginIconAttributedString(
        payload.state.icon, label: payload.state.label,
        fallback: payload.state.source, font: font,
        textColor: textColor, attributes: attrs)
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
    let labelText = payload.canCycle
        ? "Change status. Current: \(payload.state.label)"
        : "Current status: \(payload.state.label)"
    let label = htmlAttributeEscape(labelText)
    let strike = payload.state.strikethrough ? " data-strike=\"true\"" : ""
    let disabled = payload.canCycle ? "" : " disabled aria-disabled=\"true\""
    return "<button type=\"button\" class=\"multi-checkbox\" "
        + "data-plugin-offset=\"\(sourceOffset)\" aria-label=\"\(label)\" "
        + "title=\"\(label)\"\(strike)\(disabled)>\(iconHTML)</button>"
}

func sfSymbolPNGDataURI(name: String, label: String) -> String? {
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

    private static let initialStateLines = [
        #"- marker: "-""#,
        #"  label: Not started"#,
        #"  icon: "sf:circle""#,
    ]

    func isEnabled(in markdown: String) -> Bool {
        Self.configuration(in: markdown) != nil
    }

    func isDeclared(in markdown: String) -> Bool {
        Self.hasDeclaration(in: markdown)
    }

    func configurationIssue(in markdown: String) -> String? {
        Self.configurationIssue(in: markdown)
    }

    func installingDefaultConfiguration(in markdown: String) -> String? {
        Self.installingDefaultConfiguration(in: markdown)
    }

    func addingConfigurationState(in markdown: String) -> String? {
        Self.addingConfigurationState(in: markdown)
    }

    func checklistStates(in markdown: String) -> [BuiltInPluginTokenState]? {
        Self.configuration(in: markdown)?.states
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
        guard let rawStates = rawConfigurationStates(in: markdown) else { return nil }

        var states: [BuiltInPluginTokenState] = []
        var markers = Set<String>()
        for raw in rawStates {
            guard let marker = raw["marker"], (marker as NSString).length == 1,
                  marker != "[", marker != "]" else { continue }
            guard markers.insert(marker).inserted else { return nil }
            let label = raw["label"].flatMap { $0.isEmpty ? nil : $0 } ?? marker
            let icon = parseIcon(raw["icon"] ?? marker)
            let strike = parseYAMLBool(raw["strikethrough"]) ?? false
            states.append(BuiltInPluginTokenState(source: "[\(marker)]", label: label,
                                                  icon: icon, strikethrough: strike))
        }
        guard !states.isEmpty else { return nil }
        return MultiCheckboxConfiguration(states: states)
    }

    static func configurationIssue(in markdown: String) -> String? {
        guard hasDeclaration(in: markdown), configuration(in: markdown) == nil else {
            return nil
        }
        guard let rawStates = rawConfigurationStates(in: markdown) else {
            return "Invalid multi-checkbox YAML structure."
        }
        var markers = Set<String>()
        for raw in rawStates {
            guard let marker = raw["marker"] else {
                return "Every state needs a marker."
            }
            guard (marker as NSString).length == 1 else {
                return "Marker must be exactly one UTF-16 character."
            }
            guard marker != "[", marker != "]" else {
                return "Square brackets cannot be markers."
            }
            guard markers.insert(marker).inserted else {
                return "Duplicate marker: [\(marker)]."
            }
        }
        return rawStates.isEmpty
            ? "At least one state is required."
            : "Invalid multi-checkbox configuration."
    }

    private static func rawConfigurationStates(in markdown: String) -> [[String: String]]? {
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
        return rawStates
    }

    static func hasDeclaration(in markdown: String) -> Bool {
        guard let hierarchy = configurationHierarchy(in: markdown) else { return false }
        return child(named: pluginID, after: hierarchy.plugins.index,
                     parentIndent: hierarchy.plugins.indent, in: hierarchy.lines) != nil
    }

    static func installingDefaultConfiguration(in markdown: String) -> String? {
        guard !hasDeclaration(in: markdown) else { return nil }
        let pluginBlock: (Int) -> [String] = { indent in
            let prefix = String(repeating: " ", count: indent)
            let statePrefix = String(repeating: " ", count: indent + 4)
            return ["\(prefix)\(pluginID):", "\(prefix)  states:"]
                + initialStateLines.map { statePrefix + $0 }
        }

        let updated: String
        if let frontmatter = frontmatterRange(in: markdown) {
            let ns = markdown as NSString
            let body = ns.substring(with: frontmatter.body)
            var rawLines = body.components(separatedBy: "\n")
            if rawLines.count == 1, rawLines[0].isEmpty { rawLines.removeAll() }
            let lines = rawLines.map(PluginYAMLLine.init)
            if let editmd = child(named: "editmd", after: -1,
                                  parentIndent: -1, in: lines) {
                if let plugins = child(named: "plugins", after: editmd.index,
                                       parentIndent: editmd.indent, in: lines) {
                    let insertion = subtreeEnd(after: plugins.index,
                                               indent: plugins.indent, in: lines)
                    rawLines.insert(contentsOf: pluginBlock(plugins.indent + 2), at: insertion)
                } else {
                    let insertion = subtreeEnd(after: editmd.index,
                                               indent: editmd.indent, in: lines)
                    let indent = editmd.indent + 2
                    rawLines.insert(contentsOf: [
                        "\(String(repeating: " ", count: indent))plugins:",
                    ] + pluginBlock(indent + 2), at: insertion)
                }
            } else {
                if rawLines.last?.isEmpty == false { rawLines.append("") }
                rawLines += ["editmd:", "  plugins:"] + pluginBlock(4)
            }
            updated = ns.replacingCharacters(in: frontmatter.body,
                                              with: rawLines.joined(separator: "\n"))
        } else {
            let body = (["editmd:", "  plugins:"] + pluginBlock(4))
                .joined(separator: "\n")
            let block = "---\n\(body)\n---"
            updated = markdown.isEmpty ? block : "\(block)\n\n\(markdown)"
        }
        return configuration(in: updated) == nil ? nil : updated
    }

    static func addingConfigurationState(in markdown: String) -> String? {
        guard let current = configuration(in: markdown),
              let frontmatter = frontmatterRange(in: markdown) else { return nil }
        let used = Set(current.states.map(\.source))
        let markerCandidates = ["x", "+", "?", "X", "!", "~", "="]
            + (0...9).map(String.init)
            + "abcdefghijklmnopqrstuvwxyz".map(String.init)
        guard let marker = markerCandidates.first(where: { !used.contains("[\($0)]") })
        else { return nil }

        let ns = markdown as NSString
        let body = ns.substring(with: frontmatter.body)
        guard var editable = editableStateLines(in: body),
              let last = editable.validEntries.last else { return nil }
        let stateIndent = String(repeating: " ", count: editable.sequenceIndent)
        let propertyIndent = String(repeating: " ", count: editable.sequenceIndent + 2)
        editable.lines.insert(contentsOf: [
            "\(stateIndent)- marker: \(quotePluginYAMLScalar(marker))",
            "\(propertyIndent)label: \(quotePluginYAMLScalar("State \(current.states.count + 1)"))",
            "\(propertyIndent)icon: \(quotePluginYAMLScalar("sf:circle"))",
        ], at: last.endLine)
        let updated = ns.replacingCharacters(in: frontmatter.body,
                                              with: editable.lines.joined(separator: "\n"))
        guard configuration(in: updated)?.states.count == current.states.count + 1
        else { return nil }
        return updated
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

    /// Updates one visible state while preserving the rest of the frontmatter.
    /// Existing tokens migrate with a marker rename, so changing the definition
    /// cannot strand the document in an unconfigured literal state.
    static func updateConfiguration(in markdown: String, stateIndex: Int,
                                    field: BuiltInPluginConfigurationField,
                                    value: String,
                                    expectedSource: String? = nil) -> String? {
        guard stateIndex >= 0, value.utf16.count <= 256,
              !value.contains("\n"), !value.contains("\r"),
              let currentConfiguration = configuration(in: markdown),
              currentConfiguration.states.indices.contains(stateIndex),
              expectedSource == nil
                || currentConfiguration.states[stateIndex].source == expectedSource,
              let frontmatter = frontmatterRange(in: markdown)
        else { return nil }

        switch field {
        case .marker:
            guard value.utf16.count == 1, value != "[", value != "]",
                  !currentConfiguration.states.enumerated().contains(where: {
                      $0.offset != stateIndex && $0.element.source == "[\(value)]"
                  })
            else { return nil }
        case .label, .icon:
            break
        case .strikethrough:
            guard value == "true" || value == "false" else { return nil }
        }

        let original = markdown as NSString
        let body = original.substring(with: frontmatter.body)
        guard var edit = editableStateLines(in: body),
              edit.validEntries.indices.contains(stateIndex)
        else { return nil }
        let entry = edit.validEntries[stateIndex]
        let scalar = field == .strikethrough ? value : quotePluginYAMLScalar(value)
        if let lineIndex = entry.propertyLines[field.rawValue] {
            guard let replacement = replacingPluginYAMLScalar(
                in: edit.lines[lineIndex], key: field.rawValue, scalar: scalar)
            else { return nil }
            edit.lines[lineIndex] = replacement
        } else {
            let indent = String(repeating: " ", count: entry.propertyIndent)
            edit.lines.insert("\(indent)\(field.rawValue): \(scalar)", at: entry.endLine)
        }

        let mutable = NSMutableString(string: markdown)
        if field == .marker {
            let snapshot = BuiltInPluginRegistry.snapshot(for: markdown)
            let replacement = "[\(value)]"
            for token in snapshot.tokens.reversed()
            where token.payload.isInteractive && token.payload.stateIndex == stateIndex {
                mutable.replaceCharacters(in: token.range, with: replacement)
            }
        }
        mutable.replaceCharacters(in: frontmatter.body,
                                  with: edit.lines.joined(separator: "\n"))
        let updated = mutable as String
        guard let updatedConfiguration = configuration(in: updated),
              updatedConfiguration.states.count == currentConfiguration.states.count
        else { return nil }
        return updated
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

private struct EditablePluginStateEntry {
    let values: [String: String]
    let propertyLines: [String: Int]
    let endLine: Int
    let propertyIndent: Int
}

private struct EditablePluginStateLines {
    var lines: [String]
    let validEntries: [EditablePluginStateEntry]
    let sequenceIndent: Int
}

private func editableStateLines(in body: String) -> EditablePluginStateLines? {
    let rawLines = body.components(separatedBy: "\n")
    let parsed = rawLines.map(PluginYAMLLine.init)
    guard let editmd = child(named: "editmd", after: -1, parentIndent: -1, in: parsed),
          let plugins = child(named: "plugins", after: editmd.index,
                              parentIndent: editmd.indent, in: parsed),
          let plugin = child(named: MultiCheckboxPlugin.pluginID, after: plugins.index,
                             parentIndent: plugins.indent, in: parsed),
          let states = child(named: "states", after: plugin.index,
                             parentIndent: plugin.indent, in: parsed)
    else { return nil }

    var entries: [EditablePluginStateEntry] = []
    var currentValues: [String: String] = [:]
    var currentLines: [String: Int] = [:]
    var currentStart: Int?
    var sequenceIndent: Int?
    var index = states.index + 1

    func completed(endLine: Int) -> EditablePluginStateEntry? {
        guard currentStart != nil, let sequenceIndent else { return nil }
        let continuationIndent = currentLines.values
            .filter { $0 != currentStart }
            .map { parsed[$0].indent }
            .min() ?? (sequenceIndent + 2)
        return EditablePluginStateEntry(values: currentValues,
                                        propertyLines: currentLines,
                                        endLine: endLine,
                                        propertyIndent: continuationIndent)
    }

    while index < parsed.count {
        let line = parsed[index]
        if line.content.isEmpty { index += 1; continue }
        let isItem = line.content == "-" || line.content.hasPrefix("- ")
        if sequenceIndent == nil {
            guard isItem, line.indent >= states.indent else { break }
            sequenceIndent = line.indent
        }
        guard let sequenceIndent else { break }
        if line.indent < sequenceIndent || (line.indent == sequenceIndent && !isItem) {
            break
        }
        if line.indent == sequenceIndent, isItem {
            if let entry = completed(endLine: index) { entries.append(entry) }
            currentValues = [:]
            currentLines = [:]
            currentStart = index
            let remainder = line.content == "-" ? "" : String(line.content.dropFirst(2))
            if let (key, value) = yamlPair(remainder) {
                currentValues[key] = value
                currentLines[key] = index
            }
        } else if currentStart != nil, line.indent > sequenceIndent,
                  let (key, value) = yamlPair(line.content) {
            currentValues[key] = value
            currentLines[key] = index
        }
        index += 1
    }
    if let entry = completed(endLine: index) { entries.append(entry) }

    var seen = Set<String>()
    let valid = entries.filter { entry in
        guard let marker = entry.values["marker"], marker.utf16.count == 1,
              marker != "[", marker != "]", seen.insert(marker).inserted
        else { return false }
        return true
    }
    guard let sequenceIndent else { return nil }
    return EditablePluginStateLines(lines: rawLines, validEntries: valid,
                                    sequenceIndent: sequenceIndent)
}

private func configurationHierarchy(in markdown: String)
    -> (lines: [PluginYAMLLine], plugins: (index: Int, indent: Int))? {
    guard let frontmatter = frontmatterRange(in: markdown) else { return nil }
    let body = (markdown as NSString).substring(with: frontmatter.body)
    let lines = body.components(separatedBy: "\n").map(PluginYAMLLine.init)
    guard let editmd = child(named: "editmd", after: -1, parentIndent: -1, in: lines),
          let plugins = child(named: "plugins", after: editmd.index,
                              parentIndent: editmd.indent, in: lines)
    else { return nil }
    return (lines, plugins)
}

private func subtreeEnd(after index: Int, indent: Int,
                        in lines: [PluginYAMLLine]) -> Int {
    var cursor = index + 1
    while cursor < lines.count {
        let line = lines[cursor]
        if !line.content.isEmpty, line.indent <= indent { break }
        cursor += 1
    }
    return cursor
}

private func quotePluginYAMLScalar(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func replacingPluginYAMLScalar(in line: String, key: String,
                                       scalar: String) -> String? {
    let leading = String(line.prefix { $0 == " " || $0 == "\t" })
    var content = String(line.dropFirst(leading.count))
    var itemPrefix = ""
    if content.hasPrefix("- ") {
        itemPrefix = "- "
        content.removeFirst(2)
    }
    guard content.hasPrefix("\(key):") else { return nil }
    let suffix = String(content.dropFirst(key.count + 1))
    let comment: String
    if let index = pluginYAMLCommentIndex(in: suffix) {
        comment = " " + suffix[index...].trimmingCharacters(in: .whitespaces)
    } else {
        comment = ""
    }
    return "\(leading)\(itemPrefix)\(key): \(scalar)\(comment)"
}

private func pluginYAMLCommentIndex(in value: String) -> String.Index? {
    var single = false
    var double = false
    var escaped = false
    for index in value.indices {
        let char = value[index]
        if escaped { escaped = false; continue }
        if char == "\\", double { escaped = true; continue }
        if char == "'", !double { single.toggle(); continue }
        if char == "\"", !single { double.toggle(); continue }
        if char == "#", !single, !double,
           (index == value.startIndex || value[value.index(before: index)].isWhitespace) {
            return index
        }
    }
    return nil
}

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
