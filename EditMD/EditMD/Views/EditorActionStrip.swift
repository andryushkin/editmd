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
    /// Add/edit a link on the selection (⌘K) — both editing modes.
    var editLink: (() -> Void)?
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

    // Table / formula insertion works in both editing modes (Source inserts
    // raw markdown templates); the row/column ops stay Visual-only.
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
        [StripGroup.inline, .headings, .lists, .insert, .cleanup].flatMap(\.toolIDs)

    /// Pure, mode-aware source of truth for the tools the strip renders.
    /// Full Preview exposes only review-oriented actions; Split keeps Source
    /// editing tools and appends Review for selections from either pane.
    /// Both editing modes get the whole Insert group; the native table
    /// row/column ops (`table.*`) exist only where `showTableOps`.
    nonisolated static func toolIDs(for mode: EditorMode,
                                    showTableOps: Bool,
                                    showReviewAction: Bool) -> [String] {
        if mode == .preview {
            return ["strike", "highlight"] + (showReviewAction ? ["review"] : [])
                + StripGroup.theme.toolIDs
        }
        let editing = showTableOps ? editingToolIDs
            : editingToolIDs.filter { !$0.hasPrefix("table.") }
        let review = mode == .split && showReviewAction ? StripGroup.review.toolIDs : []
        return editing + review
    }

    /// Actual pill order used by layout and overflow planning.
    nonisolated static func groupIDs(for mode: EditorMode,
                                     showTableOps: Bool,
                                     showReviewAction: Bool) -> [String] {
        let ids = Set(toolIDs(for: mode,
                              showTableOps: showTableOps,
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
    /// Native table row/column ops (Visual only). Driven by mode, not by
    /// nil-ing closures on the actions bag. Table/formula *insertion* shows in
    /// both editing modes regardless.
    var showTableOps: Bool = false
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
    /// Measurement key suffix for a group's compact representation.
    private static let compactKeySuffix = ".compact"
    /// Gap to the strip's service neighbours: mode switch, "…", gutter toggle.
    private static let groupSpacing: CGFloat = 8
    /// Semantic boundary between tool groups inside the well (plan 12.1 —
    /// proximity grouping instead of hairlines; 12 pt, art-locked).
    private static let groupGap: CGFloat = 12
    /// Gap before the "…" overflow pill (service control, not a group).
    private static let overflowGap: CGFloat = 8
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
            // The strip is one bar: the tools flow from the field's left edge
            // across the whole width up to the mode switch. The right boundary
            // is ALWAYS the switch (plan 12.0) — it used to be the text
            // column's trailing margin in non-split, which parked a dead zone
            // on wide windows and collapsed groups into "…" with room to spare.
            let stripTrail = SidebarChrome.barPaddingH
            let modeWidth = widths[Self.modeKey] ?? 0
            let toolLaneWidth = Self.resolvedToolLaneWidth(
                stripWidth: geo.size.width, lead: lead, trailingInset: stripTrail,
                modeWidth: modeWidth, modeGap: Self.groupSpacing)
            let itemsByID = Dictionary(uniqueKeysWithValues:
                itemsByGroup.values.flatMap { $0 }.map { ($0.id, $0) })
            let nodesByGroup = Dictionary(uniqueKeysWithValues:
                Self.commandTree(for: mode, showTableOps: showTableOps,
                                 showReviewAction: showReviewAction)
                    .map { ($0.id, $0.children) })
            // The well's own horizontal padding eats into the lane before any
            // group does — without this the "…" collapse triggers a dozen
            // points late and the last group clips under the switcher.
            let planned = Self.layoutPlan(
                budget: toolLaneWidth - 2 * Self.toolWellPaddingH,
                groupGap: Self.groupGap,
                overflowGap: Self.overflowGap,
                overflowWidth: widths[Self.overflowKey] ?? 0,
                items: groups.map { group in
                    StripLayoutItem(
                        id: group.rawValue,
                        fullWidth: widths[group.rawValue] ?? 0,
                        compactWidth: group.compressionRank != nil
                            ? widths[group.rawValue + Self.compactKeySuffix] : nil,
                        compressionRank: group.compressionRank,
                        overflowRank: group.overflowRank)
                })
            let displayByID = Dictionary(uniqueKeysWithValues: planned)
            let visibleGroups = groups.filter { displayByID[$0.rawValue] != .overflow }
            let overflowGroups = groups.filter { displayByID[$0.rawValue] == .overflow }
            HStack(alignment: .center, spacing: 0) {
                // groupGap separates semantic groups; the "…" pill is a
                // service control and sits at the tighter overflowGap.
                HStack(alignment: .center, spacing: Self.overflowGap) {
                    HStack(alignment: .center, spacing: Self.groupGap) {
                        ForEach(visibleGroups) { group in
                            if displayByID[group.rawValue] == .compact {
                                compactPill(group, itemsByID: itemsByID,
                                            nodes: nodesByGroup[group.rawValue] ?? [])
                            } else {
                                groupPill(group, items: itemsByGroup[group] ?? [],
                                          itemsByID: itemsByID,
                                          nodes: nodesByGroup[group.rawValue] ?? [])
                            }
                        }
                    }
                    if !overflowGroups.isEmpty {
                        overflowPill(overflowGroups, itemsByID: itemsByID,
                                     nodesByGroup: nodesByGroup)
                    }
                }
                // Compact metrics: at .regular the accessory buttons carry
                // enough system padding that a ~450pt lane fit NOTHING and
                // every group fell into "…" — .small keeps the same glyphs
                // with tighter boxes, so groups survive on narrow panes.
                .controlSize(.small)
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
                // The glyph is centred in its hit target, so aligning the
                // BOX with the digits leaves the symbol visibly left of them
                // — nudge back by half the slack. Two clamps: a `barPaddingH`
                // floor (a narrow rail must not pin the toggle to the pane
                // edge) and a ceiling short of `lead` — the tool well now
                // paints from `lead`, and the toggle box used to cross it
                // invisibly, which the well turned into a visible overlap.
                let gutterWidth = widths[Self.gutterKey] ?? 0
                let ideal = field.railTrailingX - gutterWidth + Self.gutterGlyphInset
                // The groupSpacing gap to the tool well is a hard rule; the
                // barPaddingH inset from the pane edge only applies while it
                // doesn't violate that gap (a narrow rail can't have both).
                let clearance = lead - gutterWidth - Self.groupSpacing
                gutterPill
                    .offset(x: max(0, min(max(SidebarChrome.barPaddingH, ideal),
                                          clearance)))
            }
            .background(alignment: .leading) {
                measurementLayer(groups: groups, itemsByGroup: itemsByGroup,
                                 itemsByID: itemsByID, nodesByGroup: nodesByGroup)
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

    /// Tool-lane width: everything between the field's left edge and the mode
    /// switch. All metrics are explicit (plan 12.0) — the lane must NOT depend
    /// on the text column's trailing margin.
    nonisolated static func resolvedToolLaneWidth(stripWidth: CGFloat,
                                                  lead: CGFloat,
                                                  trailingInset: CGFloat,
                                                  modeWidth: CGFloat,
                                                  modeGap: CGFloat) -> CGFloat {
        max(0, stripWidth - lead - trailingInset - modeWidth - modeGap)
    }

    /// Two-stage degradation (plan 12.2). All groups start full; while the
    /// state doesn't fit the budget, groups fold into their compact menus by
    /// `compressionRank`, then leave into the shared "…" by `overflowRank`.
    /// The result keeps the input order — group order is part of the UI
    /// contract. The cost of a candidate state is recomputed from scratch on
    /// every step: sequential subtraction goes wrong exactly at the threshold.
    nonisolated static func layoutPlan(budget: CGFloat,
                                       groupGap: CGFloat,
                                       overflowGap: CGFloat,
                                       overflowWidth: CGFloat,
                                       items: [StripLayoutItem])
        -> [(id: String, display: StripGroupDisplay)] {
        guard !items.isEmpty else { return [] }
        // First frame: nothing measured yet — show everything full; the
        // visible lane's `.clipped()` covers that one frame.
        guard !items.contains(where: { $0.fullWidth <= 0 }) else {
            return items.map { ($0.id, .full) }
        }
        var display = Dictionary(uniqueKeysWithValues:
            items.map { ($0.id, StripGroupDisplay.full) })
        func cost() -> CGFloat {
            let visible = items.filter { display[$0.id] != .overflow }
            let total = visible.reduce(CGFloat(0)) { sum, item in
                sum + (display[item.id] == .compact
                    ? (item.compactWidth ?? item.fullWidth) : item.fullWidth)
            }
            let overflowing = visible.count < items.count
            return total + groupGap * CGFloat(max(0, visible.count - 1))
                + (overflowing ? overflowGap + overflowWidth : 0)
        }
        let byCompression = items
            .filter { $0.compressionRank != nil }
            .sorted { ($0.compressionRank ?? .max) < ($1.compressionRank ?? .max) }
        for item in byCompression {
            guard cost() > budget else { break }
            // An unmeasured compact width can't be planned — skip, the group
            // will fall through to overflow if the lane stays too tight.
            guard let compact = item.compactWidth, compact > 0 else { continue }
            display[item.id] = .compact
        }
        for item in items.sorted(by: { $0.overflowRank < $1.overflowRank }) {
            guard cost() > budget else { break }
            display[item.id] = .overflow
        }
        return items.map { ($0.id, display[$0.id] ?? .full) }
    }

    /// Flattened action ids of a command (sub)tree, in menu order.
    nonisolated static func flattenedCommandIDs(_ nodes: [StripCommandNode]) -> [String] {
        nodes.flatMap { $0.isLeaf ? [$0.id] : flattenedCommandIDs($0.children) }
    }

    /// Group-level command tree: top-level nodes are the strip groups (id ==
    /// group rawValue), children are the group's commands; Table and Formula
    /// are submenus inside `insert`. Single source for every representation —
    /// `flattenedCommandIDs(commandTree(…)) == toolIDs(…)` is tested.
    nonisolated static func commandTree(for mode: EditorMode,
                                        showTableOps: Bool,
                                        showReviewAction: Bool) -> [StripCommandNode] {
        let allowed = Set(toolIDs(for: mode, showTableOps: showTableOps,
                                  showReviewAction: showReviewAction))
        return groupIDs(for: mode, showTableOps: showTableOps,
                        showReviewAction: showReviewAction).compactMap { groupID in
            guard let group = StripGroup(rawValue: groupID) else { return nil }
            let children: [StripCommandNode]
            if group == .insert {
                let table = ["table", "table.addRow", "table.delRow",
                             "table.addColumn", "table.delColumn"]
                    .filter(allowed.contains).map { StripCommandNode(id: $0) }
                let math = ["math.inline", "math.block"]
                    .filter(allowed.contains).map { StripCommandNode(id: $0) }
                children = ["image", "divider", "codeblock"].filter(allowed.contains)
                    .map { StripCommandNode(id: $0) }
                    + [StripCommandNode(id: "table.menu", children: table),
                       StripCommandNode(id: "math.menu", children: math)]
            } else {
                children = group.toolIDs.filter(allowed.contains)
                    .map { StripCommandNode(id: $0) }
            }
            return StripCommandNode(id: groupID, children: children)
        }
    }

    private static func submenuTitle(_ nodeID: String) -> String {
        nodeID == "table.menu" ? String(localized: "Table") : String(localized: "Formula")
    }

    private static func submenuIcon(_ nodeID: String) -> String {
        nodeID == "table.menu" ? "tablecells" : "function"
    }

    // MARK: Overflow planning

    private var activeGroups: [StripGroup] {
        Self.groupIDs(for: mode,
                      showTableOps: showTableOps,
                      showReviewAction: showReviewAction)
            .compactMap(StripGroup.init(rawValue:))
    }

    /// Every pill laid out at its natural size, off-screen: a group that lives
    /// in the "…" menu still needs a width, or it could never come back. Both
    /// representations of the compressible groups are always measured, so the
    /// plan is a deterministic function of the lane width.
    private func measurementLayer(groups: [StripGroup],
                                  itemsByGroup: [StripGroup: [StripItem]],
                                  itemsByID: [String: StripItem],
                                  nodesByGroup: [String: [StripCommandNode]]) -> some View {
        HStack(spacing: Self.groupGap) {
            ForEach(groups) { group in
                groupPill(group, items: itemsByGroup[group] ?? [],
                          itemsByID: itemsByID,
                          nodes: nodesByGroup[group.rawValue] ?? [])
                    .measureWidth(key: group.rawValue)
            }
            ForEach(groups.filter { $0.compressionRank != nil }) { group in
                compactPill(group, itemsByID: itemsByID,
                            nodes: nodesByGroup[group.rawValue] ?? [])
                    .measureWidth(key: group.rawValue + Self.compactKeySuffix)
            }
            overflowPill([], itemsByID: itemsByID, nodesByGroup: nodesByGroup)
                .measureWidth(key: Self.overflowKey)
            modePill.measureWidth(key: Self.modeKey)
            gutterPill.measureWidth(key: Self.gutterKey)
        }
        // Must match the visible lane's control size, or the plan runs on
        // .regular widths and overflows too early.
        .controlSize(.small)
        .fixedSize()
        .hidden()
        .allowsHitTesting(false)
    }

    // MARK: Groups

    /// Full representation of one group. Content comes from the command tree:
    /// a leaf renders as a one-tap button, a submenu node as a chevron-free
    /// menu; a submenu with a single command (Source's Table) renders as a
    /// direct button — a one-item menu would cost an extra click.
    @ViewBuilder private func groupPill(_ group: StripGroup, items: [StripItem],
                                        itemsByID: [String: StripItem],
                                        nodes: [StripCommandNode]) -> some View {
        if group == .insert {
            cluster {
                ForEach(nodes, id: \.id) { node in
                    if node.isLeaf {
                        if let item = itemsByID[node.id] {
                            itemButton(item)
                        }
                    } else if node.children.count == 1,
                              let only = node.children.first,
                              let item = itemsByID[only.id] {
                        itemButton(item)
                    } else {
                        AccessoryBarMenu(systemImage: Self.submenuIcon(node.id),
                                         help: Self.submenuTitle(node.id)) {
                            menuRows(node.children, itemsByID: itemsByID)
                        }
                    }
                }
            }
        } else if group == .cleanup {
            // One eraser menu; the three utilities read by name instead of the
            // old T / Aa / aA glyph triple (and flatten into "…" as items).
            cluster {
                AccessoryBarMenu(systemImage: "eraser",
                                 help: String(localized: "Cleanup")) {
                    menuRows(nodes, itemsByID: itemsByID)
                }
            }
        } else if group == .theme {
            // One palette button; the presets live in its menu (and flatten
            // into plain items inside "…"). Themes are genuinely single-select,
            // so the Picker stays (the toggle rule covers heading/list only).
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

    /// Compact representation (plan 12.2): the whole group folds into one
    /// menu whose visible system chevron says "this is a menu".
    @ViewBuilder private func compactPill(_ group: StripGroup,
                                          itemsByID: [String: StripItem],
                                          nodes: [StripCommandNode]) -> some View {
        if group == .headings {
            // Dynamic glyph: the active level shows before any click; width is
            // reserved by the widest state so a level change never replans.
            ZStack {
                AccessoryBarMenu(glyph: .text("H3"), help: group.title,
                                 showsIndicator: true) { EmptyView() }
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                AccessoryBarMenu(glyph: .text(compactHeadingsGlyph), help: group.title,
                                 showsIndicator: true) {
                    menuRows(nodes, itemsByID: itemsByID)
                }
            }
        } else {
            AccessoryBarMenu(glyph: group == .lists ? .symbol("list.bullet") : .symbol("plus"),
                             help: group.title, showsIndicator: true) {
                menuRows(nodes, itemsByID: itemsByID)
            }
        }
    }

    /// Neutral "H" outside a heading (12.3 may switch it to "¶" by eye).
    private var compactHeadingsGlyph: String {
        if let level = activeFormats.headingLevel, (1...3).contains(level) {
            return "H\(level)"
        }
        return "H"
    }

    private func overflowPill(_ groups: [StripGroup],
                              itemsByID: [String: StripItem],
                              nodesByGroup: [String: [StripCommandNode]]) -> some View {
        AccessoryBarMenu(systemImage: "ellipsis",
                         help: String(localized: "More Tools")) {
            ForEach(groups) { group in
                Section(group.title) {
                    menuRows(nodesByGroup[group.rawValue] ?? [], itemsByID: itemsByID)
                }
            }
        }
    }

    /// Menu rows for a command (sub)tree. The tree is at most two levels deep
    /// by construction, so the recursion is written out explicitly (opaque
    /// `some View` cannot recurse).
    @ViewBuilder private func menuRows(_ nodes: [StripCommandNode],
                                       itemsByID: [String: StripItem]) -> some View {
        ForEach(nodes, id: \.id) { node in
            if node.isLeaf {
                if let item = itemsByID[node.id] {
                    menuRow(item)
                }
            } else {
                Menu(Self.submenuTitle(node.id)) {
                    ForEach(node.children, id: \.id) { child in
                        if let item = itemsByID[child.id] {
                            menuRow(item)
                        }
                    }
                }
            }
        }
    }

    /// Stateful command → Toggle (system checkmark, re-select clears, several
    /// can be on at once — Quote plus a list). Momentary command → Button.
    @ViewBuilder private func menuRow(_ item: StripItem) -> some View {
        if let active = item.active {
            Toggle(isOn: Binding(get: { active }, set: { _ in item.action() })) {
                Text(item.title)
            }
        } else {
            Button {
                item.action()
            } label: {
                Label(item.title, systemImage: item.menuIcon)
                    // macOS menus drop the icon unless the style asks for both.
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    /// Line-number toggle. Lives in the left margin instead of a tool group:
    /// it belongs to the gutter it sits over, and must never collapse into "…".
    /// Bare glyph on purpose (user call): no accessory backplate, no well —
    /// the accent tint alone carries the state, so it reads as part of the
    /// margin rather than another panel crowding the tool well.
    private var gutterPill: some View {
        Button {
            toggleLineNumbers()
        } label: {
            Image(systemName: "textformat.123")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(showLineNumbers ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .editMDHelp(showLineNumbers
            ? String(localized: "Hide Line Numbers")
            : String(localized: "Show Line Numbers"))
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
                StripItem(id: "link", glyph: .symbol("link"), title: String(localized: "Link"),
                          help: String(localized: "Add or Edit Link (⌘K)"), menuIcon: "link",
                          action: { actions.run(actions.editLink) }),
            ]
        case .review:
            items = [
                StripItem(
                    id: "review", glyph: .symbol("plus.bubble"),
                    title: String(localized: "Add Review Mark"),
                    help: String(localized: "Add Review Mark from Selection"),
                    menuIcon: "plus.bubble", action: addReviewMark),
            ]
        case .headings:
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
            ]
        case .cleanup:
            // Feeds the "…" overflow menu; the strip itself renders the group
            // as `cleanupMenu`, not from these items.
            items = [
                StripItem(id: "plain", glyph: .symbol("eraser"), title: String(localized: "Clear Inline Formatting"),
                          help: String(localized: "Plain text (clear inline formatting)"), menuIcon: "eraser",
                          action: { actions.run(actions.clearInlineFormatting) }),
                StripItem(id: "body", glyph: .symbol("paragraphsign"), title: String(localized: "Clear Heading/List"),
                          help: String(localized: "Clear Heading/List"), menuIcon: "paragraphsign",
                          action: { actions.run(actions.setBody) }),
                StripItem(id: "case", glyph: .text("aA"), title: String(localized: "Letter Case"),
                          help: String(localized: "Letter case: UPPER → lower → Capitalized"),
                          menuIcon: "characters.uppercase",
                          action: { actions.run(actions.cycleCase) }),
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
        case .insert:
            items = [
                StripItem(id: "image", glyph: .symbol("photo.badge.plus"),
                          title: String(localized: "Add Image"), help: String(localized: "Add Image…"),
                          menuIcon: "photo.badge.plus",
                          action: { actions.run(actions.insertImage) }),
                StripItem(id: "divider", glyph: .symbol("minus"), title: String(localized: "Divider Line"),
                          help: String(localized: "Divider Line (---)"), menuIcon: "minus",
                          action: { actions.run(actions.insertDivider) }),
                StripItem(id: "codeblock",
                          glyph: .symbol("chevron.left.forwardslash.chevron.right"),
                          title: String(localized: "Code Block"), help: String(localized: "Code Block"),
                          menuIcon: "chevron.left.forwardslash.chevron.right",
                          active: activeFormats.codeBlock,
                          action: { actions.run(actions.toggleCodeBlock) }),
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
                                       showTableOps: showTableOps,
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

// MARK: - Layout planner (plan 12.2)

/// One group as the width planner sees it. Internal (not private) so the
/// planner stays testable past the private `StripGroup`.
struct StripLayoutItem: Equatable {
    let id: String
    let fullWidth: CGFloat
    /// nil → the group has no compact representation.
    let compactWidth: CGFloat?
    /// Order of folding into a compact menu (smaller first); nil → never.
    let compressionRank: Int?
    /// Order of leaving into the shared "…" (smaller first).
    let overflowRank: Int
}

enum StripGroupDisplay: Equatable {
    case full, compact, overflow
}

// MARK: - Command tree (plan 12.2)

/// One node of the command tree — the single source the full pills, compact
/// menus and the "…" menu all render from. A leaf id is an action id from
/// `toolIDs`; a node with children is a submenu (its id is structural).
/// Depth is at most 2 (group → submenu → leaf) by construction.
struct StripCommandNode: Equatable {
    let id: String
    var children: [StripCommandNode] = []

    var isLeaf: Bool { children.isEmpty }
}

// MARK: - Strip model

/// Tool groups, in strip order. The trailing ones collapse into "…" first.
private enum StripGroup: String, CaseIterable, Identifiable {
    case inline, headings, lists, insert, cleanup, review, theme

    var id: String { rawValue }

    /// Section header inside the "…" menu.
    var title: String {
        switch self {
        case .inline:   return String(localized: "Inline Styles")
        case .headings: return String(localized: "Headings")
        case .lists:    return String(localized: "Lists")
        case .insert:   return String(localized: "Insert")
        case .cleanup:  return String(localized: "Cleanup")
        case .review:   return "Review"
        case .theme:    return String(localized: "Theme")
        }
    }

    var toolIDs: [String] {
        switch self {
        case .inline: return ["bold", "italic", "strike", "code", "highlight", "link"]
        case .headings: return ["h1", "h2", "h3"]
        case .lists: return ["bullet", "checklist", "numbered", "quote"]
        case .insert:
            return ["image", "divider", "codeblock",
                    "table", "table.addRow", "table.delRow", "table.addColumn",
                    "table.delColumn", "math.inline", "math.block"]
        case .cleanup: return ["plain", "body", "case"]
        case .review: return ["review"]
        case .theme:
            return PreviewTheme.allPresets.map { "theme.\($0.id)" }
        }
    }

    // Plan 12.2 degradation policy (art-locked in the plan; do not reshuffle
    // без записи решения). Inline and the single-button groups never compact.

    /// Order of folding into a compact menu; nil → the group never compacts.
    var compressionRank: Int? {
        switch self {
        case .insert: return 0
        case .lists: return 1
        case .headings: return 2
        case .inline, .cleanup, .review, .theme: return nil
        }
    }

    /// Order of leaving into the shared "…" (smaller leaves first).
    var overflowRank: Int {
        switch self {
        case .cleanup: return 0
        case .theme: return 1
        case .insert: return 2
        case .lists: return 3
        case .headings: return 4
        case .review: return 5
        case .inline: return 6
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
