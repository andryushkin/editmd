import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted (debounced) whenever any field on `EditorSettings.shared`
    /// changes — the AppKit coordinators (Source/Visual/Preview) observe this
    /// to re-render. SwiftUI reads the `@Published` fields directly instead.
    static let editorSettingsDidChange = Notification.Name("editorSettingsDidChange")
}

// MARK: - Appearance

/// Light/dark override for the whole window. `system` follows macOS.
enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
    /// `nil` = follow the system (no `.preferredColorScheme`).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Whether the window renders dark right now — resolves `.system` against
    /// the app's effective appearance so a ☀/🌙 toggle over this flips the
    /// right way. Single source for the toolbar hosts (MainChrome + ContentView).
    var isDark: Bool {
        switch self {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
}

// MARK: - Font weight

/// Codable wrapper over `NSFont.Weight` (which isn't Codable) that also maps
/// to a CSS numeric weight for the Preview.
enum FontWeight: String, Codable, CaseIterable, Identifiable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ultraLight: return String(localized: "Ultra Light")
        case .thin: return String(localized: "Thin")
        case .light: return String(localized: "Light")
        case .regular: return String(localized: "Regular")
        case .medium: return String(localized: "Medium")
        case .semibold: return String(localized: "Semibold")
        case .bold: return String(localized: "Bold")
        case .heavy: return String(localized: "Heavy")
        case .black: return String(localized: "Black")
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    var swiftUIWeight: Font.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    var cssValue: Int {
        switch self {
        case .ultraLight: return 100
        case .thin: return 200
        case .light: return 300
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        }
    }
}

// MARK: - Per-element style

/// Look of one markdown element (heading level, bold, inline code, link,
/// quote). A `nil` color/weight means "inherit the mode/theme default".
/// Applies to Visual and Preview — Source is plain raw text with no elements.
struct ElementStyle: Codable, Equatable {
    var colorHex: String?
    var weight: FontWeight?
    /// Font-size multiplier relative to the mode's base size (Visual) or `em`
    /// (Preview). 1.0 = body size; headings default > 1.
    var sizeScale: CGFloat

    init(colorHex: String? = nil, weight: FontWeight? = nil, sizeScale: CGFloat = 1.0) {
        self.colorHex = colorHex
        self.weight = weight
        self.sizeScale = sizeScale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        weight = try c.decodeIfPresent(FontWeight.self, forKey: .weight)
        sizeScale = try c.decodeIfPresent(CGFloat.self, forKey: .sizeScale) ?? 1.0
    }

    var color: NSColor? { colorHex.flatMap { NSColor(hex: $0) } }

    static let sizeScaleRange: ClosedRange<CGFloat> = 0.6...3.0
}

/// The document's element look, shared by Visual and Preview so the two stay
/// visually consistent (a WYSIWYG editor and its preview should match).
struct ElementStyles: Codable, Equatable {
    var h1, h2, h3, h4, h5, h6: ElementStyle
    var bold: ElementStyle
    var inlineCode: ElementStyle
    var link: ElementStyle
    var quote: ElementStyle

    init() {
        h1 = ElementStyle(weight: .bold, sizeScale: 1.8)
        h2 = ElementStyle(weight: .semibold, sizeScale: 1.5)
        h3 = ElementStyle(weight: .semibold, sizeScale: 1.3)
        h4 = ElementStyle(weight: .semibold, sizeScale: 1.1)
        h5 = ElementStyle(weight: .semibold, sizeScale: 1.0)
        h6 = ElementStyle(weight: .semibold, sizeScale: 0.9)
        bold = ElementStyle(weight: .bold)
        inlineCode = ElementStyle()
        link = ElementStyle()
        quote = ElementStyle()
    }

    init(from decoder: Decoder) throws {
        let d = ElementStyles()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        h1 = try c.decodeIfPresent(ElementStyle.self, forKey: .h1) ?? d.h1
        h2 = try c.decodeIfPresent(ElementStyle.self, forKey: .h2) ?? d.h2
        h3 = try c.decodeIfPresent(ElementStyle.self, forKey: .h3) ?? d.h3
        h4 = try c.decodeIfPresent(ElementStyle.self, forKey: .h4) ?? d.h4
        h5 = try c.decodeIfPresent(ElementStyle.self, forKey: .h5) ?? d.h5
        h6 = try c.decodeIfPresent(ElementStyle.self, forKey: .h6) ?? d.h6
        bold = try c.decodeIfPresent(ElementStyle.self, forKey: .bold) ?? d.bold
        inlineCode = try c.decodeIfPresent(ElementStyle.self, forKey: .inlineCode) ?? d.inlineCode
        link = try c.decodeIfPresent(ElementStyle.self, forKey: .link) ?? d.link
        quote = try c.decodeIfPresent(ElementStyle.self, forKey: .quote) ?? d.quote
    }

    func heading(_ level: Int) -> ElementStyle {
        switch level {
        case 1: return h1
        case 2: return h2
        case 3: return h3
        case 4: return h4
        case 5: return h5
        default: return h6
        }
    }
}

// MARK: - Per-mode settings

/// Per-mode knobs: font (size/family/weight), text-container padding, and an
/// optional centered reading column. `columnWidth == 0` means "full width".
struct ModeSettings: Codable, Equatable {
    var fontSize: CGFloat
    var insetH: CGFloat
    var insetV: CGFloat
    var columnWidth: CGFloat
    /// Empty string = the mode's default family (system-mono for Source,
    /// system-proportional for Visual/Preview).
    var fontFamily: String
    var fontWeight: FontWeight
    /// Per-element look (headings, bold, code, links, quotes) for THIS mode —
    /// each screen is styled independently, including Source, whose highlighter
    /// applies these to the raw markdown.
    var elements: ElementStyles
    /// Source-only: override color for Markdown syntax markers (heading `#`,
    /// list bullets, emphasis/quote/code/table/link delimiters). `nil` =
    /// `EditorTheme.markerColor` (graphite on light, soft gray on dark).
    var markerColorHex: String?
    /// Source-only: paint a fill behind the line holding the caret (Xcode-style).
    var highlightCurrentLine: Bool
    /// Tint of that fill; `nil` = `EditorTheme.currentLineColor`. Always washed
    /// by `currentLineOpacity` — an opaque band would bury the highlighting.
    var currentLineColorHex: String?
    /// Wash alpha for the band. `0` = the theme's per-appearance default.
    var currentLineOpacity: CGFloat
    /// `nil` = `EditorTheme.caretColor`.
    var caretColorHex: String?

    init(fontSize: CGFloat, insetH: CGFloat, insetV: CGFloat, columnWidth: CGFloat,
         fontFamily: String = "", fontWeight: FontWeight = .regular,
         elements: ElementStyles = ElementStyles(),
         markerColorHex: String? = nil,
         highlightCurrentLine: Bool = true,
         currentLineColorHex: String? = nil,
         currentLineOpacity: CGFloat = 0,
         caretColorHex: String? = nil) {
        self.highlightCurrentLine = highlightCurrentLine
        self.currentLineColorHex = currentLineColorHex
        self.currentLineOpacity = currentLineOpacity
        self.caretColorHex = caretColorHex
        self.fontSize = fontSize
        self.insetH = insetH
        self.insetV = insetV
        self.columnWidth = columnWidth
        self.fontFamily = fontFamily
        self.fontWeight = fontWeight
        self.elements = elements
        self.markerColorHex = markerColorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decode(CGFloat.self, forKey: .fontSize)
        insetH = try c.decode(CGFloat.self, forKey: .insetH)
        insetV = try c.decode(CGFloat.self, forKey: .insetV)
        columnWidth = try c.decode(CGFloat.self, forKey: .columnWidth)
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? ""
        fontWeight = try c.decodeIfPresent(FontWeight.self, forKey: .fontWeight) ?? .regular
        elements = try c.decodeIfPresent(ElementStyles.self, forKey: .elements) ?? ElementStyles()
        markerColorHex = try c.decodeIfPresent(String.self, forKey: .markerColorHex)
        highlightCurrentLine = try c.decodeIfPresent(Bool.self, forKey: .highlightCurrentLine) ?? true
        currentLineColorHex = try c.decodeIfPresent(String.self, forKey: .currentLineColorHex)
        currentLineOpacity = try c.decodeIfPresent(CGFloat.self, forKey: .currentLineOpacity) ?? 0
        caretColorHex = try c.decodeIfPresent(String.self, forKey: .caretColorHex)
    }

    /// Resolved Source marker-color override, or `nil` to use the theme default.
    var markerColor: NSColor? { markerColorHex.flatMap { NSColor(hex: $0) } }

    /// Tint of the fill behind the caret's line, or `nil` when the highlight is
    /// off. Opaque by design — the wash alpha (`currentLineOpacity`, or the
    /// theme default) is applied when drawing, where the appearance is known.
    /// A picked color arrives opaque and would otherwise hide the syntax.
    func currentLineTint(theme: EditorTheme) -> NSColor? {
        guard highlightCurrentLine else { return nil }
        return currentLineColorHex.flatMap { NSColor(hex: $0) } ?? theme.currentLineColor
    }

    /// Alpha the band should draw with, given the appearance it lands in.
    func currentLineAlpha(isDark: Bool) -> CGFloat {
        currentLineOpacity > 0
            ? currentLineOpacity
            : EditorTheme.currentLineAlpha(isDark: isDark)
    }

    static let currentLineOpacityRange: ClosedRange<CGFloat> = 0...0.4

    func caretColor(theme: EditorTheme) -> NSColor {
        caretColorHex.flatMap { NSColor(hex: $0) } ?? theme.caretColor
    }

    static let fontSizeRange: ClosedRange<CGFloat> = 9...40
    static let insetRange: ClosedRange<CGFloat> = 0...160
    static let columnWidthRange: ClosedRange<CGFloat> = 320...1400

    /// Horizontal/vertical text-container inset for a given content width.
    /// When `columnWidth` is set (> 0) and the view is wide enough, extra
    /// horizontal inset centers a narrower reading column.
    func textContainerInset(forWidth width: CGFloat) -> NSSize {
        guard columnWidth > 0, width > 0 else {
            return NSSize(width: insetH, height: insetV)
        }
        let available = width - insetH * 2
        let extra = max(0, (available - columnWidth) / 2)
        return NSSize(width: insetH + extra, height: insetV)
    }

    /// The mode's base font. `defaultMono` picks the fallback family when no
    /// custom `fontFamily` is chosen (Source is monospaced).
    func resolvedFont(defaultMono: Bool) -> NSFont {
        let weight = fontWeight.nsWeight
        if !fontFamily.isEmpty {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: fontFamily,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            if let font = NSFont(descriptor: descriptor, size: fontSize) { return font }
        }
        return defaultMono
            ? .monospacedSystemFont(ofSize: fontSize, weight: weight)
            : .systemFont(ofSize: fontSize, weight: weight)
    }

    /// CSS `font-family` fragment for the Preview (falls back to the system UI
    /// stack when no family is chosen).
    var cssFontFamily: String {
        fontFamily.isEmpty
            ? "-apple-system, \"Helvetica Neue\", sans-serif"
            : "\"\(fontFamily)\", -apple-system, sans-serif"
    }
}

/// Visual-only: scales the paragraph/list/quote spacing constants in
/// `VisualTextView.applyPresentation` uniformly.
struct VisualSpacingSettings: Codable, Equatable {
    var scale: CGFloat
    static let range: ClosedRange<CGFloat> = 0.5...2.0
}

/// Visual-mode large-table cell editor (overlay + input panel) tuning.
/// All values are user-configurable from Settings ▸ Visual.
struct VisualTableEditorSettings: Codable, Equatable {
    var overlayColorHex: String?
    var overlayOpacity: CGFloat
    var editorBackgroundHex: String?
    var editorTextHex: String?
    var editorTextInsetH: CGFloat
    var editorTextInsetV: CGFloat
    var editorWidthExtra: CGFloat
    var editorMinWidth: CGFloat
    var editorMaxWidthRatio: CGFloat
    var editorMinHeight: CGFloat
    var editorHeightExtra: CGFloat
    var editorMaxHeightRatio: CGFloat
    var editorViewportMargin: CGFloat
    var editorXOffset: CGFloat
    var editorCellInset: CGFloat

    init(overlayColorHex: String? = nil, overlayOpacity: CGFloat = 0.20,
         editorBackgroundHex: String? = "#FFFFFF", editorTextHex: String? = nil,
         editorTextInsetH: CGFloat = 8, editorTextInsetV: CGFloat = 6,
         editorWidthExtra: CGFloat = 140, editorMinWidth: CGFloat = 240,
         editorMaxWidthRatio: CGFloat = 0.75, editorMinHeight: CGFloat = 44,
         editorHeightExtra: CGFloat = 18, editorMaxHeightRatio: CGFloat = 0.45,
         editorViewportMargin: CGFloat = 8, editorXOffset: CGFloat = -8,
         editorCellInset: CGFloat = 2) {
        self.overlayColorHex = overlayColorHex
        self.overlayOpacity = overlayOpacity
        self.editorBackgroundHex = editorBackgroundHex
        self.editorTextHex = editorTextHex
        self.editorTextInsetH = editorTextInsetH
        self.editorTextInsetV = editorTextInsetV
        self.editorWidthExtra = editorWidthExtra
        self.editorMinWidth = editorMinWidth
        self.editorMaxWidthRatio = editorMaxWidthRatio
        self.editorMinHeight = editorMinHeight
        self.editorHeightExtra = editorHeightExtra
        self.editorMaxHeightRatio = editorMaxHeightRatio
        self.editorViewportMargin = editorViewportMargin
        self.editorXOffset = editorXOffset
        self.editorCellInset = editorCellInset
    }

    static let overlayOpacityRange: ClosedRange<CGFloat> = 0...0.7
    static let textInsetRange: ClosedRange<CGFloat> = 0...24
    static let widthExtraRange: ClosedRange<CGFloat> = 0...420
    static let minWidthRange: ClosedRange<CGFloat> = 120...800
    static let maxWidthRatioRange: ClosedRange<CGFloat> = 0.3...1.0
    static let minHeightRange: ClosedRange<CGFloat> = 24...240
    static let heightExtraRange: ClosedRange<CGFloat> = 0...180
    static let maxHeightRatioRange: ClosedRange<CGFloat> = 0.2...0.9
    static let viewportMarginRange: ClosedRange<CGFloat> = 0...48
    static let offsetRange: ClosedRange<CGFloat> = -80...80
    static let cellInsetRange: ClosedRange<CGFloat> = 0...16

    var overlayColor: NSColor {
        (overlayColorHex.flatMap(NSColor.init(hex:)) ?? NSColor(white: 0.5, alpha: 1))
            .withAlphaComponent(overlayOpacity)
    }
    var editorBackgroundColor: NSColor {
        editorBackgroundHex.flatMap(NSColor.init(hex:)) ?? .white
    }
    var editorTextColor: NSColor {
        editorTextHex.flatMap(NSColor.init(hex:)) ?? .labelColor
    }
}

/// Preview-only: CSS line-height (editor views use AppKit paragraph spacing
/// instead, which isn't comparable to a line-height multiplier) and the
/// Preview theme — a compiled-in look from `PreviewTheme.allPresets`.
struct PreviewTypographySettings: Codable, Equatable {
    var lineHeight: CGFloat
    /// `PreviewTheme` id; unknown/legacy ids resolve to the default look.
    var theme: String

    init(lineHeight: CGFloat, theme: String = "default") {
        self.lineHeight = lineHeight
        self.theme = theme
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lineHeight = try c.decode(CGFloat.self, forKey: .lineHeight)
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "default"
    }

    static let range: ClosedRange<CGFloat> = 1.2...2.2
}

// MARK: - General settings

/// Cross-mode look: theme preset, window appearance, and base color overrides.
/// A nil hex means "use the preset's own color".
/// Preset for the Review ✈️ agent launch line (plan 09 stage 4).
enum AgentCommandPreset: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude (`claude -p \"/smotr -pr\"`)"
        case .codex: return "Codex (`codex …`)"
        case .custom: return String(localized: "Custom command")
        }
    }

    /// Default argv when not using Custom / EDITMD_AGENT_CMD.
    var defaultArgv: [String] {
        switch self {
        case .claude: return ["claude", "-p", "/smotr -pr"]
        case .codex: return ["codex", "exec", "Process EditMD review queue (.smotr-queue.json)"]
        case .custom: return []
        }
    }
}

struct GeneralSettings: Codable, Equatable {
    var appearance: AppearanceMode
    var textColorHex: String?
    var accentColorHex: String?
    /// When on (default), a double-click in Finder opens the file in its own
    /// separate (sidebar-less) window; off loads it into the main window.
    var liteMode: Bool
    /// Run the local WebSocket IDE server so `claude` can attach with `/ide`
    /// (v36). Off = no server, no `~/.claude/ide/*.lock`.
    var claudeIDEEnabled: Bool
    /// When on, Review ▸ ➤ also spawns `claude -p "/smotr -pr"` in the
    /// workspace root after writing `.smotr-queue.json` (v37). Off (default) =
    /// only write the queue and copy the terminal command — matches smotr
    /// without `--agent`.
    var claudeReviewAutoSpawn: Bool
    /// Applies language-aware colors to fenced code blocks in Source, Visual,
    /// Preview and PDF. Turning it off preserves code panels and fonts.
    var syntaxHighlighting: Bool
    /// Which command ✈️ runs when auto-spawn is on (EDITMD_AGENT_CMD still wins).
    var agentCommandPreset: AgentCommandPreset
    /// Custom shell command when preset is `.custom`.
    var agentCustomCommand: String
    /// Stage 7: silent reload when buffer is clean (default on).
    var autoReloadCleanExternal: Bool

    init(appearance: AppearanceMode = .system,
         textColorHex: String? = nil, accentColorHex: String? = nil,
         liteMode: Bool = true, claudeIDEEnabled: Bool = true,
         claudeReviewAutoSpawn: Bool = false, syntaxHighlighting: Bool = true,
         agentCommandPreset: AgentCommandPreset = .claude,
         agentCustomCommand: String = "",
         autoReloadCleanExternal: Bool = true) {
        self.appearance = appearance
        self.textColorHex = textColorHex
        self.accentColorHex = accentColorHex
        self.liteMode = liteMode
        self.claudeIDEEnabled = claudeIDEEnabled
        self.claudeReviewAutoSpawn = claudeReviewAutoSpawn
        self.syntaxHighlighting = syntaxHighlighting
        self.agentCommandPreset = agentCommandPreset
        self.agentCustomCommand = agentCustomCommand
        self.autoReloadCleanExternal = autoReloadCleanExternal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex)
        accentColorHex = try c.decodeIfPresent(String.self, forKey: .accentColorHex)
        // C5: Finder double-click opens a lite window by default.
        liteMode = try c.decodeIfPresent(Bool.self, forKey: .liteMode) ?? true
        claudeIDEEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeIDEEnabled) ?? true
        claudeReviewAutoSpawn = try c.decodeIfPresent(Bool.self, forKey: .claudeReviewAutoSpawn) ?? false
        syntaxHighlighting = try c.decodeIfPresent(Bool.self, forKey: .syntaxHighlighting) ?? true
        agentCommandPreset = try c.decodeIfPresent(AgentCommandPreset.self, forKey: .agentCommandPreset) ?? .claude
        agentCustomCommand = try c.decodeIfPresent(String.self, forKey: .agentCustomCommand) ?? ""
        autoReloadCleanExternal = try c.decodeIfPresent(Bool.self, forKey: .autoReloadCleanExternal) ?? true
    }
}

// MARK: - Gutter (line numbers + session dirty marks)

/// Line-number gutter and “changed since baseline” marks for Source / Visual /
/// Preview. Marks are session-only (cleared on quit); baseline = open or
/// external apply. Git commit clear is a later stage.
struct GutterSettings: Codable, Equatable {
    /// Show 1-based line numbers in the left gutter.
    var showLineNumbers: Bool
    /// When a line differs from the session baseline, style its number (or bullet).
    var highlightChangedLines: Bool
    /// If line numbers are off, still show a small bullet on dirty lines.
    var showDirtyBulletsWhenNoNumbers: Bool
    /// Optional override for dirty mark color (nil = system green).
    var dirtyMarkColorHex: String?

    init(showLineNumbers: Bool = true,
         highlightChangedLines: Bool = true,
         showDirtyBulletsWhenNoNumbers: Bool = true,
         dirtyMarkColorHex: String? = nil) {
        self.showLineNumbers = showLineNumbers
        self.highlightChangedLines = highlightChangedLines
        self.showDirtyBulletsWhenNoNumbers = showDirtyBulletsWhenNoNumbers
        self.dirtyMarkColorHex = dirtyMarkColorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showLineNumbers = try c.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? true
        highlightChangedLines = try c.decodeIfPresent(Bool.self, forKey: .highlightChangedLines) ?? true
        showDirtyBulletsWhenNoNumbers = try c.decodeIfPresent(Bool.self, forKey: .showDirtyBulletsWhenNoNumbers) ?? true
        dirtyMarkColorHex = try c.decodeIfPresent(String.self, forKey: .dirtyMarkColorHex)
    }

    /// Resolved mark color (green by default).
    var dirtyMarkNSColor: NSColor {
        if let hex = dirtyMarkColorHex, let c = NSColor(hex: hex) { return c }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.35, green: 0.90, blue: 0.50, alpha: 1)
                : NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 1)
        }
    }

    /// Whether the gutter strip should be visible at all.
    var gutterVisible: Bool {
        showLineNumbers || (highlightChangedLines && showDirtyBulletsWhenNoNumbers)
    }
}

// MARK: - Settings store

/// Single source of truth for editor appearance, persisted to UserDefaults
/// and published for the Settings window's bindings. AppKit-side consumers
/// can't use @Published, so every change also posts `.editorSettingsDidChange`
/// — debounced, since a Visual re-render on every slider tick is expensive.
@MainActor
final class EditorSettings: ObservableObject {
    static let shared = EditorSettings()

    @Published var general: GeneralSettings { didSet { persist(general, Keys.general) } }
    @Published var gutter: GutterSettings { didSet { persist(gutter, Keys.gutter) } }
    @Published var source: ModeSettings { didSet { persist(source, Keys.source) } }
    @Published var visual: ModeSettings { didSet { persist(visual, Keys.visual) } }
    @Published var visualSpacing: VisualSpacingSettings { didSet { persist(visualSpacing, Keys.visualSpacing) } }
    @Published var visualTableEditor: VisualTableEditorSettings {
        didSet { persist(visualTableEditor, Keys.visualTableEditor) }
    }
    @Published var preview: ModeSettings { didSet { persist(preview, Keys.preview) } }
    @Published var previewTypography: PreviewTypographySettings { didSet { persist(previewTypography, Keys.previewTypography) } }

    private enum Keys {
        static let general = "editorSettings.general"
        static let gutter = "editorSettings.gutter"
        static let source = "editorSettings.source"
        static let visual = "editorSettings.visual"
        static let visualSpacing = "editorSettings.visualSpacing"
        static let visualTableEditor = "editorSettings.visualTableEditor"
        static let preview = "editorSettings.preview"
        static let previewTypography = "editorSettings.previewTypography"
    }

    private init() {
        general = Self.load(Keys.general) ?? GeneralSettings()
        gutter = Self.load(Keys.gutter) ?? GutterSettings()
        source = Self.load(Keys.source) ?? ModeSettings(
            fontSize: 14, insetH: 48, insetV: 24, columnWidth: 0)
        visual = Self.load(Keys.visual) ?? ModeSettings(
            fontSize: 15, insetH: 48, insetV: 24, columnWidth: 0)
        visualSpacing = Self.load(Keys.visualSpacing) ?? VisualSpacingSettings(scale: 1.0)
        visualTableEditor = Self.load(Keys.visualTableEditor) ?? VisualTableEditorSettings()
        preview = Self.load(Keys.preview) ?? ModeSettings(
            fontSize: 15, insetH: 32, insetV: 24, columnWidth: 736)
        previewTypography = Self.load(Keys.previewTypography) ?? PreviewTypographySettings(lineHeight: 1.6)
    }

    /// The active Source/Visual look: the single fixed editor theme plus
    /// General's base color overrides. Element-level colors are applied at draw
    /// time, not baked in here. (Preview has its own themes via `PreviewTheme`.)
    var effectiveTheme: EditorTheme {
        EditorTheme.editorDefault.applyingOverrides(general)
    }

    /// Bumps one mode's font size by `delta`, clamped. Used by ⌘=/⌘−, which
    /// now act on whichever mode is focused rather than one app-wide size.
    func adjustFontSize(_ mode: ReferenceWritableKeyPath<EditorSettings, ModeSettings>, by delta: CGFloat) {
        var settings = self[keyPath: mode]
        settings.fontSize = min(ModeSettings.fontSizeRange.upperBound,
                                max(ModeSettings.fontSizeRange.lowerBound, settings.fontSize + delta))
        self[keyPath: mode] = settings
    }

    func resetGeneral() { general = GeneralSettings() }
    func resetGutter() { gutter = GutterSettings() }
    func resetSource() { source = ModeSettings(fontSize: 14, insetH: 48, insetV: 24, columnWidth: 0) }
    func resetVisual() {
        visual = ModeSettings(fontSize: 15, insetH: 48, insetV: 24, columnWidth: 0)
        visualSpacing = VisualSpacingSettings(scale: 1.0)
        visualTableEditor = VisualTableEditorSettings()
    }
    func resetPreview() {
        preview = ModeSettings(fontSize: 15, insetH: 32, insetV: 24, columnWidth: 736)
        previewTypography = PreviewTypographySettings(lineHeight: 1.6)
    }

    func resetToDefaults() {
        general = GeneralSettings()
        resetGutter()
        resetSource(); resetVisual(); resetPreview()
    }

    private var notifyTask: Task<Void, Never>?

    private func persist<T: Codable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // Debounce the (expensive) coordinator re-renders: a slider drag fires
        // dozens of didSets; coalesce them into one notification.
        notifyTask?.cancel()
        notifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, self != nil else { return }
            NotificationCenter.default.post(name: .editorSettingsDidChange, object: nil)
        }
    }

    private static func load<T: Codable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Font families

enum FontCatalog {
    // Enumerating installed fonts is not free; the set is stable for a launch,
    // so compute each list once (SwiftUI re-reads them on every render).

    /// Proportional + monospaced families, for the Visual/Preview picker.
    static let allFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    /// Fixed-pitch families only, for the Source picker.
    static let monospacedFamilies: [String] = {
        let manager = NSFontManager.shared
        let mask = Int(NSFontTraitMask.fixedPitchFontMask.rawValue)
        return manager.availableFontFamilies.filter { family in
            guard let members = manager.availableMembers(ofFontFamily: family) else { return false }
            // A member row is [name, style, weight, traitsMask]; the fixed-pitch
            // bit lives in the mask at index 3 (an NSNumber when bridged).
            return members.contains { row in
                guard row.count > 3, let traits = (row[3] as? NSNumber)?.intValue else { return false }
                return traits & mask != 0
            }
        }.sorted()
    }()
}

// MARK: - NSColor <-> hex

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "#000000" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Resolves a (possibly dynamic) color to concrete hex in the given
    /// appearance — used to bake theme colors into Preview CSS.
    func hexString(for appearance: NSAppearance) -> String {
        var result = "#000000"
        appearance.performAsCurrentDrawingAppearance {
            result = self.hexString
        }
        return result
    }
}
