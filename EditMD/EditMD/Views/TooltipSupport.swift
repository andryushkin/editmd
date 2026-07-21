import SwiftUI
import AppKit

/// AppKit-backed tooltip so the standard gray plaque always appears on hover.
/// SwiftUI `.help` alone is flaky on plain icon buttons (often no plaque at all).
private final class TooltipNSView: NSView {
    /// Pass hits through to the SwiftUI button above/below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct AppKitTooltip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = TooltipNSView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

extension View {
    /// Project-wide hover tooltip (gray plaque). Prefer this over bare `.help`
    /// for icon-only controls.
    func editMDHelp(_ text: String) -> some View {
        self
            .help(text)
            .background(AppKitTooltip(text: text))
            .accessibilityLabel(text)
    }
}

// MARK: - Pasteboard helpers

/// Absolute path → general pasteboard (context menus, Info panel).
func copyPathToPasteboard(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.path, forType: .string)
}

// MARK: - Shared chrome (sidebar navigator + folder action strip)

/// Metrics and well color shared by the Files/Outline pill and the folder
/// info action strip so both sit on one horizontal band.
enum SidebarChrome {
    /// Outer padding around the top navigator / action strip (must match
    /// between sidebars and folder-info). Vertical is intentionally tight —
    /// Xcode sits the capsule flush under the toolbar with no air gap.
    static let barPaddingH: CGFloat = 8
    static let barPaddingTop: CGFloat = 0
    static let barPaddingBottom: CGFloat = 0

    /// Gap from the bottom of the top chrome to the first workspace row /
    /// folder-info title. Matches Files tab: LazyVStack vertical pad (6) +
    /// workspace group `.padding(.top, 8)`.
    static let firstContentTop: CGFloat = 14

    /// Square floor cell for one navigator tab. Equal sides → selection reads
    /// as a true circle at the pane floor (Xcode); was 28×24 which made a squat
    /// oval even at minimum.
    static let iconButtonWidth: CGFloat = 24
    static let iconButtonHeight: CGFloat = 24

    /// Inner horizontal pad of the gray capsule. Tight like Xcode's strip —
    /// was 5 and left a visible air gap at either end of a min-width pane.
    static let navPillPaddingH: CGFloat = 3

    /// Hairline between tabs (drawn as a zero-layout overlay — see
    /// `SidebarNavStrip`). Only the stroke width matters; no side padding,
    /// otherwise min-width packs looser than Xcode.
    static let navDividerWidth: CGFloat = 1
    static let navDividerHeight: CGFloat = 12

    /// Selection pill grows with its cell up to this width, then centres.
    /// ~1.75× height ≈ Xcode's moderate oval; without the cap a 4-tab strip
    /// on a wide pane becomes a full-cell sausage.
    static let navSelectionMaxWidth: CGFloat = 42

    /// Width the navigator capsule needs to show `tabs` buttons in full.
    /// Hairlines are overlays and do NOT add to the budget — only icon cells
    /// + capsule pad. Pinned by `PaneLayoutTests`.
    static func navigatorPillWidth(tabs: Int) -> CGFloat {
        CGFloat(tabs) * iconButtonWidth + 2 * navPillPaddingH
    }

    /// Cap on the reading column for the welcome / folder-info center panes so
    /// full-width rows don't stretch edge-to-edge on a wide window. Welcome
    /// centers within it (minus insets); folder-info left-aligns.
    static let maxReadingWidth: CGFloat = 720

    /// Soft well gray for icon pills (Files/Outline, folder actions, filter).
    /// Kept lighter than a typical control fill so the plaque stays subtle.
    static let wellColor = NSColor(name: nil) { appearance in
        switch appearance.name {
        case .darkAqua, .vibrantDark,
             .accessibilityHighContrastDarkAqua,
             .accessibilityHighContrastVibrantDark:
            // Was ~0.24 — slightly lifted so the pill reads on window chrome.
            return NSColor(srgbRed: 0.32, green: 0.32, blue: 0.33, alpha: 1)
        default:
            // Was ~0.90 (#E5E5EA) — closer to white / window background.
            return NSColor(srgbRed: 0.945, green: 0.945, blue: 0.955, alpha: 1)
        }
    }
}

/// One tab of a sidebar navigator strip.
struct SidebarNavTab: Identifiable, Equatable {
    let id: String
    let systemImage: String
    /// Tooltip and VoiceOver label.
    let help: String
    /// Pending-work count (e.g. open review marks). Drawn as a small accent
    /// dot on the icon when > 0 and the tab is not selected.
    var badge: Int = 0

    init(id: String, systemImage: String, help: String, badge: Int = 0) {
        self.id = id
        self.systemImage = systemImage
        self.help = help
        self.badge = badge
    }

    /// Tooltip: the plain name, or the name plus the pending count.
    var tooltip: String {
        badge > 0 ? String(localized: "\(help) · \(badge) open") : help
    }
}

/// The navigator capsule shared by the left workspace sidebar and the right
/// inspector: icon tabs on a recessed gray well, hairlines between them.
///
/// Hit targets share the pane width equally. The selection pill only grows up
/// to `navSelectionMaxWidth` and stays centred. Hairlines are trailing
/// *overlays* (zero layout width) so hiding the ones that flank the selection
/// does not leave empty gaps — packing at min width matches Xcode.
struct SidebarNavStrip: View {
    let tabs: [SidebarNavTab]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                SidebarNavTabButton(
                    systemImage: tab.systemImage,
                    help: tab.tooltip,
                    selected: selection == tab.id,
                    badge: tab.badge,
                    showsTrailingDivider: showsDividerAfter(index: index)
                ) { selection = tab.id }
            }
        }
        .padding(.horizontal, SidebarChrome.navPillPaddingH)
        // 2pt: Xcode's capsule hugs the selection circle; 4pt left a visible
        // air band above/below the blue pill at min width.
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: SidebarChrome.wellColor))
        )
    }

    /// Hairline after tab `index`, unless it would sit against the selection
    /// (Xcode drops those two strokes).
    private func showsDividerAfter(index: Int) -> Bool {
        guard index < tabs.count - 1 else { return false }
        let left = tabs[index].id
        let right = tabs[index + 1].id
        return selection != left && selection != right
    }
}

/// One navigator tab. The button's hit area flexes with the pane; the blue
/// selection is a separate, width-capped layer centred on the icon.
///
/// Xcode rule: at the pane floor the highlight is a **circle** (diameter =
/// cell height). Only when the cell grows wider than that does it become a
/// capsule oval — never a squat Capsule(28×24)-style oval at minimum.
struct SidebarNavTabButton: View {
    let systemImage: String
    let help: String
    let selected: Bool
    var badge: Int = 0
    /// Hairline painted on the trailing edge (overlay — no layout width).
    var showsTrailingDivider: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                // Dot tracks the glyph, not the far edge of a wide cell.
                .overlay(alignment: .topTrailing) {
                    if badge > 0 && !selected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 4, y: -2)
                    }
                }
                .frame(minWidth: SidebarChrome.iconButtonWidth,
                       maxWidth: .infinity,
                       minHeight: SidebarChrome.iconButtonHeight,
                       maxHeight: SidebarChrome.iconButtonHeight)
                .background {
                    if selected {
                        GeometryReader { geo in
                            selectionHighlight(in: geo.size)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    if showsTrailingDivider {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: SidebarChrome.navDividerWidth,
                                   height: SidebarChrome.navDividerHeight)
                    }
                }
                // Full cell is clickable, not just the pill.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .editMDHelp(help)
    }

    /// Floor → `Circle` with diameter = icon height. Wider cell → `Capsule`
    /// growing from that diameter up to `navSelectionMaxWidth`, centred.
    @ViewBuilder
    private func selectionHighlight(in size: CGSize) -> some View {
        let diameter = SidebarChrome.iconButtonHeight
        // min(cell, cap): at the 24pt floor this equals `diameter` → circle;
        // on a wide pane it grows into an oval, then stops at the cap.
        let pillWidth = min(size.width, SidebarChrome.navSelectionMaxWidth)
        Group {
            if pillWidth <= diameter + 0.5 {
                // True circle — `Capsule` on equal sides still looks slightly
                // off next to Xcode's hard circle at minimum width.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: diameter, height: diameter)
            } else {
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: pillWidth, height: diameter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
