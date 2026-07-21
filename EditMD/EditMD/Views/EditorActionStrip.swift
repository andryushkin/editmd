import SwiftUI
import AppKit

// MARK: - Action bag (all modes)

/// Closures the top action strip invokes. Modes publish what they support;
/// nil → button hidden or beeps. Shared by Source / Visual / Preview.
/// Closure bag for the action strip. Not an ObservableObject on purpose:
/// bindings are installed from `updateNSView` / format publishers; publishing
/// `objectWillChange` during a view update freezes SwiftUI.
@MainActor
final class EditorStripActions {
    var toggleBold: (() -> Void)?
    var toggleItalic: (() -> Void)?
    var toggleStrikethrough: (() -> Void)?
    var toggleCodeSpan: (() -> Void)?
    var toggleHighlight: (() -> Void)?
    /// Heading 1…3 (Title / Heading / Subheading).
    var setHeading: ((Int) -> Void)?
    /// Plain paragraph (strip structure).
    var setBody: (() -> Void)?
    /// Clear inline styles only (B4).
    var clearInlineFormatting: (() -> Void)?
    var insertDivider: (() -> Void)?
    var cycleCase: (() -> Void)?
    var toggleCodeBlock: (() -> Void)?
    var toggleBulletList: (() -> Void)?
    var toggleChecklist: (() -> Void)?
    var toggleNumberedList: (() -> Void)?
    var toggleQuote: (() -> Void)?
    var insertImage: (() -> Void)?

    // Visual-only
    var insertTable: (() -> Void)?
    var tableAddRow: (() -> Void)?
    var tableDeleteRow: (() -> Void)?
    var tableAddColumn: (() -> Void)?
    var tableDeleteColumn: (() -> Void)?
    var insertInlineFormula: (() -> Void)?
    var insertBlockFormula: (() -> Void)?

    /// Active inline formats at caret — drives accent tint on B/I/`/S (B6).
    var activeFormats: ActiveInlineFormats = ActiveInlineFormats()

    func run(_ action: (() -> Void)?) {
        guard let action else { NSSound.beep(); return }
        action()
    }
}

// MARK: - Strip UI

/// Top accessory bar over the editor — system `.accessoryBar` tool groups
/// plus a stock segmented mode switcher pinned to the trailing edge.
/// The leading inset matches the active mode's reading field. Tool groups
/// that no longer fit the space between them collapse into an "…" menu — the
/// switcher must never be overlapped.
struct EditorActionStrip: View {
    nonisolated private static let editingToolIDs =
        [StripGroup.inline, .paragraph, .lists].flatMap(\.toolIDs)
    nonisolated private static let visualExtraToolIDs = StripGroup.extras.toolIDs

    /// Pure, mode-aware source of truth for the tools the strip renders.
    /// Full Preview exposes only review-oriented actions; Split keeps Source
    /// editing tools and appends Review for selections from either pane.
    nonisolated static func toolIDs(for mode: EditorMode,
                                    showVisualExtras: Bool,
                                    showReviewAction: Bool) -> [String] {
        if mode == .preview {
            return ["strike", "highlight"] + (showReviewAction ? ["review"] : [])
                + StripGroup.theme.toolIDs
        }
        let extras = mode == .visual && showVisualExtras ? visualExtraToolIDs : []
        let review = mode == .split && showReviewAction ? StripGroup.review.toolIDs : []
        return editingToolIDs + review + extras
    }

    /// Actual pill order used by layout and overflow planning.
    nonisolated static func groupIDs(for mode: EditorMode,
                                     showVisualExtras: Bool,
                                     showReviewAction: Bool) -> [String] {
        let ids = Set(toolIDs(for: mode,
                              showVisualExtras: showVisualExtras,
                              showReviewAction: showReviewAction))
        return StripGroup.allCases.compactMap { group in
            group.toolIDs.contains(where: ids.contains) ? group.rawValue : nil
        }
    }

    /// Closures only — not observed for UI identity (mutating them must not
    /// republish during `updateNSView` or SwiftUI freezes).
    var actions: EditorStripActions
    /// Source / Visual / Preview inset for column alignment.
    var insetH: CGFloat
    var columnWidth: CGFloat
    /// Width of the Source pane in split, used only to align the tools' left
    /// edge and the gutter toggle over that pane's text/numbers (field
    /// geometry) and to pick the split trailing padding. It does NOT bound the
    /// tool lane — the tools flow across the whole strip up to the mode switch.
    /// nil (non-split) means the strip spans the whole editor area.
    var editingPaneWidth: CGFloat? = nil
    /// Left edge of the text as reported by Source/Visual (their inset already
    /// reserves the numbers margin). nil → compute it (Preview).
    var textLeading: CGFloat? = nil
    /// Numbers → text gap, so the toggle lands over the digits.
    var railGap: CGFloat = 0
    /// Preview only: its rail (numbers + gap) widens the text's left padding,
    /// and nobody reports the result — so the strip adds it itself.
    var previewRailWidth: CGFloat = 0
    /// Table + formula tools (Visual only). Driven by mode, not by nil-ing
    /// closures on the actions bag.
    var showVisualExtras: Bool = false
    /// Review compose exists only in the main workspace window, which owns the
    /// Review sidebar. Lite windows keep this false and omit the button.
    var showReviewAction: Bool = false
    var addReviewMark: () -> Void = {}
    /// B6: tint B/I/`/S when caret is inside those styles.
    var activeFormats: ActiveInlineFormats = ActiveInlineFormats()
    /// Mode switcher — pinned to the trailing edge of the strip (the window
    /// toolbar no longer carries it).
    var mode: EditorMode
    var setEditorMode: (EditorMode) -> Void
    /// Line-number toggle, drawn over the gutter it controls.
    var showLineNumbers: Bool
    var toggleLineNumbers: () -> Void

    /// Measured pill widths, keyed by `StripGroup.rawValue` + the two reserved
    /// keys below. Filled by the hidden measurement layer; pill widths don't
    /// depend on the available width, so this settles on the first pass.
    @State private var widths: [String: CGFloat] = [:]

    private static let modeKey = "__mode"
    private static let overflowKey = "__overflow"
    private static let gutterKey = "__gutter"
    private static let groupSpacing: CGFloat = 8
    /// Inner horizontal pad of the shared tool well.
    private static let toolWellPaddingH: CGFloat = 6
    /// Optical nudge for the toggle: half the empty space around its glyph.
    private static let gutterGlyphInset: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            // Build every StripItem once per body pass. The same instances feed
            // visible pills, overflow and the hidden measurement layer.
            let groups = activeGroups
            let itemsByGroup = Dictionary(uniqueKeysWithValues:
                groups.map { ($0, items(for: $0)) })
            let editingWidth = Self.resolvedEditingPaneWidth(
                stripWidth: geo.size.width, editingPaneWidth: editingPaneWidth)
            let field = field(for: editingWidth)
            let lead = field.textLeading
            // The strip is one bar spanning Source + Preview, so the tools flow
            // across the whole width up to the mode switch — they no longer stop
            // at the split divider. Clipping them to the Source pane left the bar
            // half empty while groups collapsed into "…" with room to spare.
            // `laneBeforeMode` already reserves the switch's width, so overflow
            // triggers only when the full-width lane is genuinely too tight.
            let fieldTrail = max(field.textTrailing, SidebarChrome.barPaddingH)
            let stripTrail = editingPaneWidth == nil
                ? fieldTrail : SidebarChrome.barPaddingH
            let modeWidth = widths[Self.modeKey] ?? 0
            let laneBeforeMode = max(0, geo.size.width - lead - stripTrail
                                       - modeWidth - Self.groupSpacing)
            let toolLaneWidth = laneBeforeMode
            // The well's own horizontal padding eats into the lane before any
            // group does — without this the "…" collapse triggers a dozen
            // points late and the last group clips under the switcher.
            let plan = plan(available: toolLaneWidth - 2 * Self.toolWellPaddingH,
                            groups: groups)
            HStack(alignment: .center, spacing: 0) {
                HStack(alignment: .center, spacing: Self.groupSpacing) {
                    ForEach(plan.visible) { group in
                        groupPill(group, items: itemsByGroup[group] ?? [])
                    }
                    if !plan.overflow.isEmpty {
                        overflowPill(plan.overflow, itemsByGroup: itemsByGroup)
                    }
                }
                // One shared well behind ALL the tools (user-picked look):
                // hugs the visible buttons, mirrors the segmented switcher's
                // bezel so the two read as sibling panels on the strip.
                .padding(.horizontal, Self.toolWellPaddingH)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .quaternarySystemFill))
                )
                .frame(width: toolLaneWidth, alignment: .leading)
                // Belt and braces: even if a pill measures wider than planned,
                // it gets clipped instead of drawing over the switcher.
                .clipped()
                Spacer(minLength: Self.groupSpacing)
                modePill
            }
            .padding(.leading, lead)
            .padding(.trailing, stripTrail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // Sits in the left margin, centred over the numbers column — the
            // rail is reserved either way, so it never moves.
            .overlay(alignment: .leading) {
                gutterPill
                    // The glyph is centred in its hit target, so aligning the
                    // BOX with the digits leaves the symbol visibly left of them
                    // — nudge back by half the slack. Floor of `barPaddingH`:
                    // a narrow rail must not pin the toggle to the pane edge.
                    .offset(x: max(SidebarChrome.barPaddingH,
                                   field.railTrailingX
                                      - (widths[Self.gutterKey] ?? 0)
                                      + Self.gutterGlyphInset))
            }
            .background(alignment: .leading) {
                measurementLayer(groups: groups, itemsByGroup: itemsByGroup)
            }
            // One deliberate toolbar backing across the whole width. The tools
            // flow across Source + Preview up to the reserved mode switch;
            // without a bar they read as two floating clusters with a gap. The
            // bar ties them into a single strip spanning both panes.
            .background { stripBar }
            .onPreferenceChange(StripWidthKey.self) { widths = $0 }
        }
        .frame(height: stripHeight)
    }

    nonisolated static func resolvedEditingPaneWidth(stripWidth: CGFloat,
                                                     editingPaneWidth: CGFloat?) -> CGFloat {
        min(max(0, editingPaneWidth ?? stripWidth), max(0, stripWidth))
    }

    // MARK: Overflow planning

    private var activeGroups: [StripGroup] {
        Self.groupIDs(for: mode,
                      showVisualExtras: showVisualExtras,
                      showReviewAction: showReviewAction)
            .compactMap(StripGroup.init(rawValue:))
    }

    /// Greedy left-to-right fit. Until the measurement layer reports (first
    /// frame) every group is shown — `.clipped()` covers that one frame.
    private func plan(available: CGFloat, groups: [StripGroup])
        -> (visible: [StripGroup], overflow: [StripGroup]) {
        let measured = groups.map { widths[$0.rawValue] ?? 0 }
        guard !measured.contains(where: { $0 <= 0 }) else { return (groups, []) }
        let total = measured.reduce(0, +)
            + Self.groupSpacing * CGFloat(max(0, groups.count - 1))
        if total <= available { return (groups, []) }

        let budget = available - (widths[Self.overflowKey] ?? 0) - Self.groupSpacing
        var visible: [StripGroup] = []
        var used: CGFloat = 0
        for (group, width) in zip(groups, measured) {
            let cost = visible.isEmpty ? width : width + Self.groupSpacing
            guard used + cost <= budget else { break }
            visible.append(group)
            used += cost
        }
        return (visible, groups.filter { !visible.contains($0) })
    }

    /// Every pill laid out at its natural size, off-screen: a group that lives
    /// in the "…" menu still needs a width, or it could never come back.
    private func measurementLayer(groups: [StripGroup],
                                  itemsByGroup: [StripGroup: [StripItem]]) -> some View {
        HStack(spacing: Self.groupSpacing) {
            ForEach(groups) { group in
                groupPill(group, items: itemsByGroup[group] ?? [])
                    .measureWidth(key: group.rawValue)
            }
            overflowPill([], itemsByGroup: itemsByGroup)
                .measureWidth(key: Self.overflowKey)
            modePill.measureWidth(key: Self.modeKey)
            gutterPill.measureWidth(key: Self.gutterKey)
        }
        .fixedSize()
        .hidden()
        .allowsHitTesting(false)
    }

    // MARK: Groups

    @ViewBuilder private func groupPill(_ group: StripGroup, items: [StripItem]) -> some View {
        if group == .extras {
            // Table / formula stay menus in the strip; the "…" menu flattens
            // them into plain items.
            cluster {
                tableMenu
                formulaMenu
            }
        } else if group == .theme {
            // One palette button; the presets live in its menu (and flatten
            // into plain items inside "…").
            cluster {
                themeMenu
            }
        } else {
            cluster {
                ForEach(items) { item in
                    itemButton(item)
                }
            }
        }
    }

    private func overflowPill(_ groups: [StripGroup],
                              itemsByGroup: [StripGroup: [StripItem]]) -> some View {
        AccessoryBarMenu(systemImage: "ellipsis",
                         help: String(localized: "More Tools")) {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(itemsByGroup[group] ?? []) { item in
                        Button {
                            item.action()
                        } label: {
                            Label(item.title, systemImage: item.menuIcon)
                                // macOS menus drop the icon unless the
                                // style asks for both.
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
        }
    }

    /// Line-number toggle. Lives in the left margin instead of a tool group:
    /// it belongs to the gutter it sits over, and must never collapse into "…".
    private var gutterPill: some View {
        AccessoryBarButton(
            glyph: .symbol("textformat.123"),
            help: showLineNumbers
                ? String(localized: "Hide Line Numbers")
                : String(localized: "Show Line Numbers"),
            active: showLineNumbers
        ) {
            toggleLineNumbers()
        }
        .fixedSize()
    }

    /// The mode switcher is the same stock segmented control as the sidebar
    /// navigators, at its intrinsic width (`fit`) — system selection, no
    /// hand-drawn pill.
    private var modePill: some View {
        SidebarNavStrip(
            tabs: EditorMode.allCases.map { candidate in
                SidebarNavTab(id: candidate.rawValue,
                              systemImage: candidate.systemImage,
                              help: "\(candidate.title) (\(candidate.shortcutHint))")
            },
            selection: Binding(
                get: { mode.rawValue },
                set: { if let picked = EditorMode(rawValue: $0) { setEditorMode(picked) } }
            ),
            fillsWidth: false,
            controlSize: .regular
        )
        .fixedSize()
    }

    // MARK: Items (one model for the pill and the "…" menu)

    private func items(for group: StripGroup) -> [StripItem] {
        let items: [StripItem]
        switch group {
        case .inline:
            items = [
                StripItem(id: "bold", glyph: .symbol("bold"), title: String(localized: "Bold"),
                          help: String(localized: "Bold (**…**)"), menuIcon: "bold",
                          active: activeFormats.bold,
                          action: { actions.run(actions.toggleBold) }),
                StripItem(id: "italic", glyph: .symbol("italic"), title: String(localized: "Italic"),
                          help: String(localized: "Italic (*…*)"), menuIcon: "italic",
                          active: activeFormats.italic,
                          action: { actions.run(actions.toggleItalic) }),
                StripItem(id: "strike", glyph: .symbol("strikethrough"), title: String(localized: "Strikethrough"),
                          help: String(localized: "Strikethrough (~~…~~)"), menuIcon: "strikethrough",
                          active: activeFormats.strikethrough,
                          action: { actions.run(actions.toggleStrikethrough) }),
                StripItem(id: "code", glyph: .text("<>"), title: String(localized: "Inline Code"),
                          help: String(localized: "Inline Code (`…`)"),
                          menuIcon: "chevron.left.forwardslash.chevron.right",
                          active: activeFormats.code,
                          action: { actions.run(actions.toggleCodeSpan) }),
                StripItem(id: "highlight", glyph: .symbol("highlighter"), title: String(localized: "Highlight"),
                          help: String(localized: "Highlight (==…==)"), menuIcon: "highlighter",
                          active: activeFormats.highlight,
                          action: { actions.run(actions.toggleHighlight) }),
                StripItem(id: "image", glyph: .symbol("photo.badge.plus"),
                          title: String(localized: "Add Image"), help: String(localized: "Add Image…"),
                          menuIcon: "photo.badge.plus",
                          action: { actions.run(actions.insertImage) }),
            ]
        case .review:
            items = [
                StripItem(
                    id: "review", glyph: .symbol("plus.bubble"),
                    title: String(localized: "Add Review Mark"),
                    help: String(localized: "Add Review Mark from Selection"),
                    menuIcon: "plus.bubble", action: addReviewMark),
            ]
        case .paragraph:
            items = [
                StripItem(id: "h1", glyph: .text("H1"), title: String(localized: "Heading 1"),
                          help: String(localized: "Heading 1 (#)"), menuIcon: "textformat.size.larger",
                          active: activeFormats.headingLevel == 1,
                          action: { runHeading(1) }),
                StripItem(id: "h2", glyph: .text("H2"), title: String(localized: "Heading 2"),
                          help: String(localized: "Heading 2 (##)"), menuIcon: "textformat.size",
                          active: activeFormats.headingLevel == 2,
                          action: { runHeading(2) }),
                StripItem(id: "h3", glyph: .text("H3"), title: String(localized: "Heading 3"),
                          help: String(localized: "Heading 3 (###)"), menuIcon: "textformat.size.smaller",
                          active: activeFormats.headingLevel == 3,
                          action: { runHeading(3) }),
                StripItem(id: "plain", glyph: .text("T"), title: String(localized: "Clear Inline Formatting"),
                          help: String(localized: "Plain text (clear inline formatting)"), menuIcon: "eraser",
                          action: { actions.run(actions.clearInlineFormatting) }),
                StripItem(id: "body", glyph: .text("Aa"), title: String(localized: "Clear Heading/List"),
                          help: String(localized: "Clear Heading/List"), menuIcon: "paragraphsign",
                          action: { actions.run(actions.setBody) }),
                StripItem(id: "case", glyph: .text("aA"), title: String(localized: "Letter Case"),
                          help: String(localized: "Letter case: UPPER → lower → Capitalized"),
                          menuIcon: "characters.uppercase",
                          action: { actions.run(actions.cycleCase) }),
                StripItem(id: "divider", glyph: .symbol("minus"), title: String(localized: "Divider Line"),
                          help: String(localized: "Divider Line (---)"), menuIcon: "minus",
                          action: { actions.run(actions.insertDivider) }),
                StripItem(id: "codeblock",
                          glyph: .symbol("chevron.left.forwardslash.chevron.right"),
                          title: String(localized: "Code Block"), help: String(localized: "Code Block"),
                          menuIcon: "chevron.left.forwardslash.chevron.right",
                          active: activeFormats.codeBlock,
                          action: { actions.run(actions.toggleCodeBlock) }),
            ]
        case .lists:
            items = [
                StripItem(id: "bullet", glyph: .symbol("list.bullet"),
                          title: String(localized: "Bulleted List"), help: String(localized: "Bulleted List"),
                          menuIcon: "list.bullet",
                          active: activeFormats.bulletList,
                          action: { actions.run(actions.toggleBulletList) }),
                StripItem(id: "checklist", glyph: .symbol("checklist"),
                          title: String(localized: "Checklist"), help: String(localized: "Checklist"), menuIcon: "checklist",
                          active: activeFormats.checklist,
                          action: { actions.run(actions.toggleChecklist) }),
                StripItem(id: "numbered", glyph: .symbol("list.number"),
                          title: String(localized: "Numbered List"), help: String(localized: "Numbered List"),
                          menuIcon: "list.number",
                          active: activeFormats.numberedList,
                          action: { actions.run(actions.toggleNumberedList) }),
                StripItem(id: "quote", glyph: .symbol("text.quote"),
                          title: String(localized: "Quote"), help: String(localized: "Quote"), menuIcon: "text.quote",
                          active: activeFormats.quote,
                          action: { actions.run(actions.toggleQuote) }),
            ]
        case .theme:
            // Feeds the "…" overflow menu; the strip itself renders the group
            // as `themeMenu`, not from these items.
            let current = PreviewTheme.preset(
                named: EditorSettings.shared.previewTypography.theme).id
            items = PreviewTheme.allPresets.map { preset in
                StripItem(id: "theme.\(preset.id)", glyph: .symbol("paintpalette"),
                          title: preset.title, help: preset.title,
                          menuIcon: current == preset.id ? "checkmark" : "paintpalette",
                          active: current == preset.id,
                          action: { EditorSettings.shared.previewTypography.theme = preset.id })
            }
        case .extras:
            items = [
                StripItem(id: "table", glyph: .symbol("tablecells"),
                          title: String(localized: "Insert 3×3 Table"), help: String(localized: "Table"),
                          menuIcon: "tablecells",
                          action: { actions.run(actions.insertTable) }),
                StripItem(id: "table.addRow", glyph: .symbol("tablecells"),
                          title: String(localized: "Add Row"), help: String(localized: "Add Row"),
                          menuIcon: "plus.rectangle",
                          action: { actions.run(actions.tableAddRow) }),
                StripItem(id: "table.delRow", glyph: .symbol("tablecells"),
                          title: String(localized: "Delete Row"), help: String(localized: "Delete Row"),
                          menuIcon: "minus.rectangle",
                          action: { actions.run(actions.tableDeleteRow) }),
                StripItem(id: "table.addColumn", glyph: .symbol("tablecells"),
                          title: String(localized: "Add Column"), help: String(localized: "Add Column"),
                          menuIcon: "plus.rectangle.portrait",
                          action: { actions.run(actions.tableAddColumn) }),
                StripItem(id: "table.delColumn", glyph: .symbol("tablecells"),
                          title: String(localized: "Delete Column"), help: String(localized: "Delete Column"),
                          menuIcon: "minus.rectangle.portrait",
                          action: { actions.run(actions.tableDeleteColumn) }),
                StripItem(id: "math.inline", glyph: .symbol("function"),
                          title: String(localized: "Inline Formula  $…$"), help: String(localized: "Inline Formula"),
                          menuIcon: "function",
                          action: { actions.run(actions.insertInlineFormula) }),
                StripItem(id: "math.block", glyph: .symbol("function"),
                          title: String(localized: "Block Formula  $$…$$"), help: String(localized: "Block Formula"),
                          menuIcon: "sum",
                          action: { actions.run(actions.insertBlockFormula) }),
            ]
        }
        let allowed = Set(Self.toolIDs(for: mode,
                                       showVisualExtras: showVisualExtras,
                                       showReviewAction: showReviewAction))
        return items.filter { allowed.contains($0.id) }
    }

    private func runHeading(_ level: Int) {
        if let setHeading = actions.setHeading { setHeading(level) } else { NSSound.beep() }
    }

    private func itemButton(_ item: StripItem) -> some View {
        AccessoryBarButton(glyph: item.glyph, help: item.help,
                           active: item.active, action: item.action)
    }

    // MARK: Table menu (Visual)

    private var tableMenu: some View {
        AccessoryBarMenu(systemImage: "tablecells",
                         help: String(localized: "Table")) {
            Button("Insert 3×3 Table") { actions.run(actions.insertTable) }
            Divider()
            Button("Add Row") { actions.run(actions.tableAddRow) }
            Button("Delete Row") { actions.run(actions.tableDeleteRow) }
            Button("Add Column") { actions.run(actions.tableAddColumn) }
            Button("Delete Column") { actions.run(actions.tableDeleteColumn) }
        }
    }

    // MARK: Formula menu (Visual)

    private var formulaMenu: some View {
        AccessoryBarMenu(systemImage: "function",
                         help: String(localized: "Formula")) {
            Button("Inline Formula  $…$") { actions.run(actions.insertInlineFormula) }
            Button("Block Formula  $$…$$") { actions.run(actions.insertBlockFormula) }
        }
    }

    // MARK: Preview theme menu (Preview)

    private var themeMenu: some View {
        AccessoryBarMenu(systemImage: "paintpalette",
                         help: String(localized: "Preview theme")) {
            Picker("Theme", selection: Binding(
                get: { EditorSettings.shared.previewTypography.theme },
                set: { EditorSettings.shared.previewTypography.theme = $0 })) {
                ForEach(PreviewTheme.allPresets, id: \.id) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    // MARK: Chrome

    private var stripHeight: CGFloat { SidebarChrome.barHeight }

    /// Full-width strip backing. `windowBackgroundColor` matches the sidebar
    /// panes; on macOS 26 it равно `textBackgroundColor`, so the strip reads
    /// flush with a default-themed editor — deliberate after the explicit
    /// band tint was rejected by eye.
    private var stripBar: some View {
        Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor))
    }

    /// Preview reports nothing — its column is centred in CSS, and the rail
    /// (numbers + gap) sits inside the body's left padding.
    private func field(for width: CGFloat) -> EditorFieldGeometry {
        let sideMargin: CGFloat = columnWidth > 0 && width > 0
            ? max(0, (width - min(columnWidth, width)) / 2)
            : 0
        let trailing = sideMargin + insetH
        let leading = textLeading ?? (trailing + previewRailWidth)
        return EditorFieldGeometry(textLeading: leading,
                                   textTrailing: trailing,
                                   railGap: railGap)
    }

    /// One tool group: accessory-bar controls packed tight, no background —
    /// the system style draws hover/pressed/on shapes per control, so the
    /// capsule wells and hand-drawn hairlines are gone. Zero spacing: each
    /// control already carries the style's own padding.
    private func cluster<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
    }
}

// MARK: - Strip model

/// Tool groups, in strip order. The trailing ones collapse into "…" first.
private enum StripGroup: String, CaseIterable, Identifiable {
    case inline, paragraph, lists, review, extras, theme

    var id: String { rawValue }

    /// Section header inside the "…" menu.
    var title: String {
        switch self {
        case .inline:    return String(localized: "Inline Styles")
        case .review:    return "Review"
        case .paragraph: return String(localized: "Paragraph")
        case .lists:     return String(localized: "Lists")
        case .extras:    return String(localized: "Tables & Formulas")
        case .theme:     return String(localized: "Theme")
        }
    }

    var toolIDs: [String] {
        switch self {
        case .inline: return ["bold", "italic", "strike", "code", "highlight", "image"]
        case .review: return ["review"]
        case .paragraph:
            return ["h1", "h2", "h3", "plain", "body", "case", "divider", "codeblock"]
        case .lists: return ["bullet", "checklist", "numbered", "quote"]
        case .extras:
            return ["table", "table.addRow", "table.delRow", "table.addColumn",
                    "table.delColumn", "math.inline", "math.block"]
        case .theme:
            return PreviewTheme.allPresets.map { "theme.\($0.id)" }
        }
    }
}

/// One button: drawn as a glyph in the strip, as an icon + title in the "…"
/// menu. Text-glyph buttons (H1, `<>`, Aa…) have no symbol to reuse there, so
/// `menuIcon` names one explicitly.
///
/// `active == nil` → momentary action (plain button). A `Bool` → the control
/// renders as a toggle whose on-state tracks it (bold at caret, current
/// heading level).
private struct StripItem: Identifiable {
    typealias Glyph = AccessoryBarButton.Glyph

    let id: String
    let glyph: Glyph
    let title: String
    let help: String
    let menuIcon: String
    var active: Bool? = nil
    let action: () -> Void
}

// MARK: - Width measurement

private struct StripWidthKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat],
                       nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    func measureWidth(key: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: StripWidthKey.self,
                                       value: [key: proxy.size.width])
            }
        )
    }
}
