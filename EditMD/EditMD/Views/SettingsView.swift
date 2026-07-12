import SwiftUI

/// The app's Settings window (⌘,): a tab per editor screen. Each mode tab
/// owns its full look — font (size/family/weight), margins, reading column,
/// and per-element styles (headings, bold, code, links, quotes) — so Source,
/// Visual and Preview are styled independently. Source applies its element
/// styles by highlighting the raw markdown. The General tab holds the shared
/// theme preset, window appearance, and base color overrides. Every control
/// writes straight into `EditorSettings.shared`, the same source of truth
/// `ContentView` reads — there is no separate apply step.
struct SettingsView: View {
    @ObservedObject private var settings = EditorSettings.shared

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModeTab(settings: settings, mode: \.source, monospaced: true,
                    resetAction: settings.resetSource, extra: .none)
                .tabItem { Label("Source", systemImage: "chevron.left.forwardslash.chevron.right") }
            ModeTab(settings: settings, mode: \.visual, monospaced: false,
                    resetAction: settings.resetVisual, extra: .spacing)
                .tabItem { Label("Visual", systemImage: "doc.richtext") }
            ModeTab(settings: settings, mode: \.preview, monospaced: false,
                    resetAction: settings.resetPreview, extra: .lineHeight)
                .tabItem { Label("Preview", systemImage: "eye") }
        }
        .frame(width: 720, height: 720)
        // The Settings window is its own scene — follow the appearance
        // override too, or it stays on the system theme while editing it.
        .preferredColorScheme(settings.general.appearance.colorScheme)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: EditorSettings

    private var preset: EditorTheme { EditorTheme.preset(named: settings.general.themePreset) }

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Preset", selection: $settings.general.themePreset) {
                    ForEach(EditorTheme.allPresets, id: \.id) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                }
                Picker("Appearance", selection: $settings.general.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Code highlighting") {
                Toggle("Syntax highlighting in fenced code blocks",
                       isOn: $settings.general.syntaxHighlighting)
                Text("Uses the language after the opening fence, for example ```bash or ```swift. Unlabelled blocks stay plain for predictable results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Base colors") {
                ColorOverrideRow(title: "Text", hex: $settings.general.textColorHex,
                                 fallback: preset.textColor)
                ColorOverrideRow(title: "Accent / links", hex: $settings.general.accentColorHex,
                                 fallback: preset.accentColor)
                Text("Per-element colors are set separately on each mode tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Windows") {
                Toggle("Lite mode — open files from Finder in a separate window",
                       isOn: $settings.general.liteMode)
                Text("Off: a double-click in Finder loads the file into the main window. Sidebar clicks and File ▸ Open always use the main window; right-click a file to open it separately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code") {
                Toggle("Claude Code integration", isOn: $settings.general.claudeIDEEnabled)
                Text("Runs a local server on 127.0.0.1 so `claude` in your terminal can attach with /ide: it then sees the current file, your selection and the workspace, and proposes edits as a diff you accept or reject. No API key is stored and nothing leaves your machine.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Auto-run Claude for Review queue",
                       isOn: $settings.general.claudeReviewAutoSpawn)
                Text("When on, the Review sidebar ➤ button writes `.smotr-queue.json` and spawns `claude -p \"/smotr -pr\"` in the workspace root (opt-in; off by default). When off, ➤ only prepares the queue and copies the terminal command.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Line gutter") {
                Toggle("Show line numbers", isOn: $settings.gutter.showLineNumbers)
                Toggle("Highlight lines changed this session",
                       isOn: $settings.gutter.highlightChangedLines)
                Toggle("Show bullets on changed lines when numbers are off",
                       isOn: $settings.gutter.showDirtyBulletsWhenNoNumbers)
                ColorOverrideRow(title: "Changed-line mark",
                                 hex: $settings.gutter.dirtyMarkColorHex,
                                 fallback: settings.gutter.dirtyMarkNSColor)
                Text("Marks compare to the text when the file was opened or last reloaded from disk. They clear when the app quits (session-only). Git commit clear comes next.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset Gutter to Defaults") { settings.resetGutter() }
            }
            Section {
                Button("Reset General to Defaults") { settings.resetGeneral() }
                Button("Reset Everything…", role: .destructive) { settings.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Per-mode tab

/// Extra controls a mode tab appends: Visual gets a spacing scale, Preview a
/// line-height.
private enum ModeExtra { case none, spacing, lineHeight }

private struct ModeTab: View {
    @ObservedObject var settings: EditorSettings
    let mode: ReferenceWritableKeyPath<EditorSettings, ModeSettings>
    let monospaced: Bool
    let resetAction: () -> Void
    let extra: ModeExtra

    private var m: Binding<ModeSettings> {
        Binding(get: { settings[keyPath: mode] }, set: { settings[keyPath: mode] = $0 })
    }
    private var families: [String] {
        monospaced ? FontCatalog.monospacedFamilies : FontCatalog.allFamilies
    }
    private var theme: EditorTheme { settings.effectiveTheme }

    var body: some View {
        Form {
            Section("Font") {
                FontSizeStepper(title: "Size", value: m.fontSize)
                FontFamilyPicker(title: "Family", family: m.fontFamily, families: families)
                Picker("Weight", selection: m.fontWeight) {
                    ForEach(FontWeight.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Margins") {
                ValueSlider(title: "Horizontal", value: m.insetH, range: ModeSettings.insetRange)
                // Top/bottom inset of the reading field (under the action strip).
                ValueSlider(title: "Vertical", value: m.insetV, range: ModeSettings.insetRange)
                Text("Vertical is the gap under the formatting strip (and above the bottom of the page).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reading column") {
                Toggle("Limit column width", isOn: columnEnabled)
                if m.wrappedValue.columnWidth > 0 {
                    ValueSlider(title: "Width", value: m.columnWidth,
                                range: ModeSettings.columnWidthRange)
                }
            }
            switch extra {
            case .none:
                EmptyView()
            case .spacing:
                Section("Spacing") {
                    ValueSlider(title: "Paragraph & list spacing",
                                value: $settings.visualSpacing.scale,
                                range: VisualSpacingSettings.range, format: "%.2f×")
                }
                Section("Large table editor") {
                    let v = $settings.visualTableEditor
                    ColorOverrideRow(title: "Overlay color", hex: v.overlayColorHex,
                                     fallback: NSColor(white: 0.5, alpha: 1))
                    ValueSlider(title: "Overlay opacity", value: v.overlayOpacity,
                                range: VisualTableEditorSettings.overlayOpacityRange,
                                format: "%.2f")
                    ColorOverrideRow(title: "Input background", hex: v.editorBackgroundHex,
                                     fallback: .white)
                    ColorOverrideRow(title: "Input text", hex: v.editorTextHex,
                                     fallback: .labelColor)
                    ValueSlider(title: "Text inset horizontal", value: v.editorTextInsetH,
                                range: VisualTableEditorSettings.textInsetRange, format: "%.0f")
                    ValueSlider(title: "Text inset vertical", value: v.editorTextInsetV,
                                range: VisualTableEditorSettings.textInsetRange, format: "%.0f")
                    ValueSlider(title: "Width extra", value: v.editorWidthExtra,
                                range: VisualTableEditorSettings.widthExtraRange, format: "%.0f")
                    ValueSlider(title: "Min width", value: v.editorMinWidth,
                                range: VisualTableEditorSettings.minWidthRange, format: "%.0f")
                    ValueSlider(title: "Max width ratio", value: v.editorMaxWidthRatio,
                                range: VisualTableEditorSettings.maxWidthRatioRange,
                                format: "%.2f")
                    ValueSlider(title: "Min height", value: v.editorMinHeight,
                                range: VisualTableEditorSettings.minHeightRange, format: "%.0f")
                    ValueSlider(title: "Height extra", value: v.editorHeightExtra,
                                range: VisualTableEditorSettings.heightExtraRange, format: "%.0f")
                    ValueSlider(title: "Max height ratio", value: v.editorMaxHeightRatio,
                                range: VisualTableEditorSettings.maxHeightRatioRange,
                                format: "%.2f")
                    ValueSlider(title: "Viewport margin", value: v.editorViewportMargin,
                                range: VisualTableEditorSettings.viewportMarginRange, format: "%.0f")
                    ValueSlider(title: "X offset", value: v.editorXOffset,
                                range: VisualTableEditorSettings.offsetRange, format: "%.0f")
                    ValueSlider(title: "Cell inset", value: v.editorCellInset,
                                range: VisualTableEditorSettings.cellInsetRange, format: "%.0f")
                }
            case .lineHeight:
                Section("Typography") {
                    ValueSlider(title: "Line height", value: $settings.previewTypography.lineHeight,
                                range: PreviewTypographySettings.range, format: "%.2f×")
                }
            }
            Section("Headings") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    elementHeaderRow
                    elementRow("H1", m.elements.h1, showSize: true, showWeight: true, fallback: theme.textColor)
                    elementRow("H2", m.elements.h2, showSize: true, showWeight: true, fallback: theme.textColor)
                    elementRow("H3", m.elements.h3, showSize: true, showWeight: true, fallback: theme.textColor)
                    elementRow("H4", m.elements.h4, showSize: true, showWeight: true, fallback: theme.textColor)
                    elementRow("H5", m.elements.h5, showSize: true, showWeight: true, fallback: theme.textColor)
                    elementRow("H6", m.elements.h6, showSize: true, showWeight: true, fallback: theme.textColor)
                }
            }
            Section("Inline") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    elementRow("Bold", m.elements.bold, showSize: false, showWeight: true, fallback: theme.textColor)
                    elementRow("Code", m.elements.inlineCode, showSize: false, showWeight: false, fallback: theme.inlineCodeColor)
                    elementRow("Link", m.elements.link, showSize: false, showWeight: false, fallback: theme.accentColor)
                    elementRow("Quote", m.elements.quote, showSize: false, showWeight: false, fallback: theme.textColor)
                }
            }
            Section("Sample") {
                StyleSample(mode: m.wrappedValue, theme: theme, monospaced: monospaced)
            }
            Section { Button("Reset This Tab") { resetAction() } }
        }
        .formStyle(.grouped)
    }

    private var columnEnabled: Binding<Bool> {
        Binding(get: { m.wrappedValue.columnWidth > 0 },
                set: { on in m.wrappedValue.columnWidth = on ? 720 : 0 })
    }

    // MARK: Element grid

    /// Column headers for the element grid (Size / Weight / Color).
    private var elementHeaderRow: some View {
        GridRow {
            Text("")
            Text("Size").font(.caption2).foregroundStyle(.secondary)
            Text("Weight").font(.caption2).foregroundStyle(.secondary)
            Text("Color").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// One element's row in the grid: label + optional size stepper + optional
    /// weight menu + color well. Empty cells keep the columns aligned. Using a
    /// Grid (not a per-row HStack in a Form) frees the controls from Form's
    /// label/value split, which was squeezing them.
    @ViewBuilder
    private func elementRow(_ title: String, _ element: Binding<ElementStyle>,
                           showSize: Bool, showWeight: Bool, fallback: NSColor) -> some View {
        GridRow {
            Text(title).frame(width: 40, alignment: .leading)
            if showSize {
                Stepper(value: doubleBinding(element.sizeScale),
                        in: doubleRange(ElementStyle.sizeScaleRange), step: 0.05) {
                    Text(String(format: "%.2f×", element.wrappedValue.sizeScale))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .leading)
                }
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
            if showWeight {
                Picker("", selection: element.weight) {
                    Text("Default").tag(FontWeight?.none)
                    ForEach(FontWeight.allCases) { Text($0.label).tag(FontWeight?.some($0)) }
                }
                .labelsHidden()
                .frame(width: 140)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
            HStack(spacing: 8) {
                ColorPicker("", selection: elementColorBinding(element, fallback),
                            supportsOpacity: false)
                    .labelsHidden()
                if element.wrappedValue.colorHex != nil {
                    Button {
                        element.wrappedValue.colorHex = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to default")
                }
            }
        }
    }

    private func elementColorBinding(_ element: Binding<ElementStyle>,
                                     _ fallback: NSColor) -> Binding<Color> {
        Binding(
            get: { element.wrappedValue.color.map { Color(nsColor: $0) } ?? Color(nsColor: fallback) },
            set: { element.wrappedValue.colorHex = NSColor($0).hexString }
        )
    }
}

// MARK: - Reusable controls

/// Numeric font-size control: a text field for exact entry plus a stepper.
///
/// Uses a local string draft instead of `TextField(value:format:)`. The
/// format-style field was unreliable here: Settings re-renders on every
/// `@Published` write (including nested ModeSettings projections), which
/// rebuilds the `Double` bridge binding and aborts in-progress edits — the
/// field looked dead or snapped back. Draft text only commits on Submit /
/// focus loss; the stepper still writes `value` directly.
private struct FontSizeStepper: View {
    let title: String
    @Binding var value: CGFloat
    var range = ModeSettings.fontSizeRange

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", text: $draft)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { commitDraft() }
            Stepper("", value: $value, in: range, step: 1).labelsHidden()
            Text("pt").foregroundStyle(.secondary)
        }
        .onAppear { draft = Self.format(value) }
        // macOS 13 deployment: single-parameter onChange (two-param needs 14+).
        .onChange(of: value) { new in
            // Keep the field in sync with the stepper / external writes, but
            // don't clobber text the user is mid-edit.
            if !isFocused { draft = Self.format(new) }
        }
        .onChange(of: isFocused) { focused in
            if !focused { commitDraft() }
        }
    }

    private func commitDraft() {
        let normalized = draft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(normalized) else {
            draft = Self.format(value)
            return
        }
        let clamped = min(range.upperBound, max(range.lowerBound, CGFloat(parsed.rounded())))
        value = clamped
        draft = Self.format(clamped)
    }

    private static func format(_ v: CGFloat) -> String {
        String(format: "%.0f", v)
    }
}

/// A slider with a live numeric readout — for fuzzy values (margins, column
/// width, scales) where exact numbers matter less than font size.
private struct ValueSlider: View {
    let title: String
    @Binding var value: CGFloat
    var range: ClosedRange<CGFloat>
    var format = "%.0f pt"

    var body: some View {
        HStack {
            Text(title)
            Slider(value: doubleBinding($value), in: doubleRange(range))
            Text(String(format: format, value))
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct FontFamilyPicker: View {
    let title: String
    @Binding var family: String
    let families: [String]

    var body: some View {
        Picker(title, selection: $family) {
            Text("System Default").tag("")
            Divider()
            ForEach(families, id: \.self) { Text($0).tag($0) }
        }
    }
}

/// ColorPicker bound to an optional hex override: nil shows the fallback
/// (theme) color; picking writes the override; Reset clears back to default.
private struct ColorOverrideRow: View {
    let title: String
    @Binding var hex: String?
    let fallback: NSColor

    var body: some View {
        HStack {
            ColorPicker(title, selection: colorBinding, supportsOpacity: false)
            if hex != nil {
                Button("Reset") { hex = nil }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { hex.flatMap { NSColor(hex: $0) }.map { Color(nsColor: $0) } ?? Color(nsColor: fallback) },
            set: { hex = NSColor($0).hexString }
        )
    }
}

// MARK: - Live sample

/// A small preview of the mode's font + element styles, updated live.
private struct StyleSample: View {
    let mode: ModeSettings
    let theme: EditorTheme
    let monospaced: Bool

    private var elements: ElementStyles { mode.elements }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headingLine("Heading 1", elements.h1, defaultWeight: .bold)
            headingLine("Heading 2", elements.h2, defaultWeight: .semibold)
            bodyLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func headingLine(_ text: String, _ style: ElementStyle,
                             defaultWeight: FontWeight) -> some View {
        Text(text)
            .font(font(size: mode.fontSize * style.sizeScale,
                       weight: style.weight ?? defaultWeight))
            .foregroundStyle(color(style.color, fallback: theme.textColor))
    }

    private var bodyLine: some View {
        // Built by reducing a run array — a single giant `Text + Text + …`
        // literal with per-run modifiers blows up the type-checker.
        let body = color(nil, fallback: theme.textColor)
        let runs: [(String, Color, FontWeight?)] = [
            ("Body with ", body, nil),
            ("bold", color(elements.bold.color, fallback: theme.textColor), elements.bold.weight ?? .bold),
            (", ", body, nil),
            ("code", color(elements.inlineCode.color, fallback: theme.inlineCodeColor), nil),
            (", a ", body, nil),
            ("link", color(elements.link.color, fallback: theme.accentColor), nil),
            (" and ", body, nil),
            ("quote", color(elements.quote.color, fallback: theme.textColor), nil),
            (".", body, nil),
        ]
        let text = runs.reduce(Text("")) { acc, run in
            var piece = Text(run.0).foregroundColor(run.1)
            if let weight = run.2 { piece = piece.fontWeight(weight.swiftUIWeight) }
            return acc + piece
        }
        return text.font(font(size: mode.fontSize, weight: mode.fontWeight))
    }

    private func font(size: CGFloat, weight: FontWeight) -> Font {
        if !mode.fontFamily.isEmpty {
            return .custom(mode.fontFamily, size: size).weight(weight.swiftUIWeight)
        }
        return monospaced
            ? .system(size: size, weight: weight.swiftUIWeight, design: .monospaced)
            : .system(size: size, weight: weight.swiftUIWeight)
    }

    private func color(_ override: NSColor?, fallback: NSColor) -> Color {
        Color(nsColor: override ?? fallback)
    }
}

// MARK: - Binding helpers

/// Bridges a `CGFloat` binding (AppKit's currency) to the `Double` that
/// SwiftUI's Slider/TextField/Stepper number formatting want.
private func doubleBinding(_ binding: Binding<CGFloat>) -> Binding<Double> {
    Binding(get: { Double(binding.wrappedValue) },
            set: { binding.wrappedValue = CGFloat($0) })
}

private func doubleRange(_ range: ClosedRange<CGFloat>) -> ClosedRange<Double> {
    Double(range.lowerBound)...Double(range.upperBound)
}

