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
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
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
}

// MARK: - Font weight

/// Codable wrapper over `NSFont.Weight` (which isn't Codable) that also maps
/// to a CSS numeric weight for the Preview.
enum FontWeight: String, Codable, CaseIterable, Identifiable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ultraLight: return "Ultra Light"
        case .thin: return "Thin"
        case .light: return "Light"
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .semibold: return "Semibold"
        case .bold: return "Bold"
        case .heavy: return "Heavy"
        case .black: return "Black"
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

    init(fontSize: CGFloat, insetH: CGFloat, insetV: CGFloat, columnWidth: CGFloat,
         fontFamily: String = "", fontWeight: FontWeight = .regular,
         elements: ElementStyles = ElementStyles()) {
        self.fontSize = fontSize
        self.insetH = insetH
        self.insetV = insetV
        self.columnWidth = columnWidth
        self.fontFamily = fontFamily
        self.fontWeight = fontWeight
        self.elements = elements
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

/// Preview-only: CSS line-height (editor views use AppKit paragraph spacing
/// instead, which isn't comparable to a line-height multiplier).
struct PreviewTypographySettings: Codable, Equatable {
    var lineHeight: CGFloat
    static let range: ClosedRange<CGFloat> = 1.2...2.2
}

// MARK: - General settings

/// Cross-mode look: theme preset, window appearance, and base color overrides.
/// A nil hex means "use the preset's own color".
struct GeneralSettings: Codable, Equatable {
    var themePreset: String
    var appearance: AppearanceMode
    var textColorHex: String?
    var accentColorHex: String?
    /// When on, a double-click in Finder opens the file in its own separate
    /// (sidebar-less) window; off (default) loads it into the main window.
    var liteMode: Bool

    init(themePreset: String, appearance: AppearanceMode = .system,
         textColorHex: String? = nil, accentColorHex: String? = nil,
         liteMode: Bool = false) {
        self.themePreset = themePreset
        self.appearance = appearance
        self.textColorHex = textColorHex
        self.accentColorHex = accentColorHex
        self.liteMode = liteMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        themePreset = try c.decodeIfPresent(String.self, forKey: .themePreset) ?? "github"
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex)
        accentColorHex = try c.decodeIfPresent(String.self, forKey: .accentColorHex)
        liteMode = try c.decodeIfPresent(Bool.self, forKey: .liteMode) ?? false
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
    @Published var source: ModeSettings { didSet { persist(source, Keys.source) } }
    @Published var visual: ModeSettings { didSet { persist(visual, Keys.visual) } }
    @Published var visualSpacing: VisualSpacingSettings { didSet { persist(visualSpacing, Keys.visualSpacing) } }
    @Published var preview: ModeSettings { didSet { persist(preview, Keys.preview) } }
    @Published var previewTypography: PreviewTypographySettings { didSet { persist(previewTypography, Keys.previewTypography) } }

    private enum Keys {
        static let general = "editorSettings.general"
        static let source = "editorSettings.source"
        static let visual = "editorSettings.visual"
        static let visualSpacing = "editorSettings.visualSpacing"
        static let preview = "editorSettings.preview"
        static let previewTypography = "editorSettings.previewTypography"
    }

    private init() {
        general = Self.load(Keys.general) ?? GeneralSettings(themePreset: "github")
        source = Self.load(Keys.source) ?? ModeSettings(
            fontSize: 14, insetH: 48, insetV: 24, columnWidth: 0)
        visual = Self.load(Keys.visual) ?? ModeSettings(
            fontSize: 15, insetH: 48, insetV: 24, columnWidth: 0)
        visualSpacing = Self.load(Keys.visualSpacing) ?? VisualSpacingSettings(scale: 1.0)
        preview = Self.load(Keys.preview) ?? ModeSettings(
            fontSize: 15, insetH: 32, insetV: 24, columnWidth: 736)
        previewTypography = Self.load(Keys.previewTypography) ?? PreviewTypographySettings(lineHeight: 1.6)
    }

    /// The active theme: the chosen preset plus General's color overrides.
    /// Element-level colors are applied at draw time, not baked in here.
    var effectiveTheme: EditorTheme {
        EditorTheme.preset(named: general.themePreset).applyingOverrides(general)
    }

    /// Bumps one mode's font size by `delta`, clamped. Used by ⌘=/⌘−, which
    /// now act on whichever mode is focused rather than one app-wide size.
    func adjustFontSize(_ mode: ReferenceWritableKeyPath<EditorSettings, ModeSettings>, by delta: CGFloat) {
        var settings = self[keyPath: mode]
        settings.fontSize = min(ModeSettings.fontSizeRange.upperBound,
                                max(ModeSettings.fontSizeRange.lowerBound, settings.fontSize + delta))
        self[keyPath: mode] = settings
    }

    func resetGeneral() { general = GeneralSettings(themePreset: general.themePreset) }
    func resetSource() { source = ModeSettings(fontSize: 14, insetH: 48, insetV: 24, columnWidth: 0) }
    func resetVisual() {
        visual = ModeSettings(fontSize: 15, insetH: 48, insetV: 24, columnWidth: 0)
        visualSpacing = VisualSpacingSettings(scale: 1.0)
    }
    func resetPreview() {
        preview = ModeSettings(fontSize: 15, insetH: 32, insetV: 24, columnWidth: 736)
        previewTypography = PreviewTypographySettings(lineHeight: 1.6)
    }

    func resetToDefaults() {
        general = GeneralSettings(themePreset: "github")
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
