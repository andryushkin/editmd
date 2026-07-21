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
    /// Outer padding around the top navigator / action strip (must match).
    static let barPaddingH: CGFloat = 8
    static let barPaddingTop: CGFloat = 8
    static let barPaddingBottom: CGFloat = 6

    /// Gap from the bottom of the top chrome to the first workspace row /
    /// folder-info title. Matches Files tab: LazyVStack vertical pad (6) +
    /// workspace group `.padding(.top, 8)`.
    static let firstContentTop: CGFloat = 14

    /// Icon hit target inside the gray capsule (Files/Outline and folder actions).
    static let iconButtonWidth: CGFloat = 28
    static let iconButtonHeight: CGFloat = 24

    /// Slack a navigator tab needs beyond its icon, and the padding of the
    /// strip itself. The strip is a stock segmented control now, so these no
    /// longer draw anything — they survive as the budget behind the pane
    /// floor, whose values are pinned by `PaneLayoutTests`.
    static let navPillPaddingH: CGFloat = 5
    static let navDividerWidth: CGFloat = 1
    static let navDividerPaddingH: CGFloat = 3

    /// Width the navigator strip needs to show `tabs` icons comfortably. The
    /// segmented control squeezes below this instead of clipping the trailing
    /// tabs, but the icons stop being legible — so it stays the pane floor.
    static func navigatorPillWidth(tabs: Int) -> CGFloat {
        let dividers = max(0, tabs - 1)
        return CGFloat(tabs) * iconButtonWidth
            + CGFloat(dividers) * (navDividerWidth + 2 * navDividerPaddingH)
            + 2 * navPillPaddingH
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
struct SidebarNavTab: Identifiable {
    let id: String
    let systemImage: String
    /// Accessibility label (VoiceOver); the segmented control has no per-tab
    /// tooltip, so this is the only place the tab names itself.
    let help: String
    /// Symbol shown while `badge > 0`. A segmented control leaves no room for
    /// a badge dot, so a pending tab swaps in a filled variant instead.
    var badgeSystemImage: String?
    var badge: Int = 0

    init(id: String, systemImage: String, help: String,
         badgeSystemImage: String? = nil, badge: Int = 0) {
        self.id = id
        self.systemImage = systemImage
        self.help = help
        self.badgeSystemImage = badgeSystemImage
        self.badge = badge
    }

    var symbol: String {
        badge > 0 ? (badgeSystemImage ?? systemImage) : systemImage
    }
}

/// The navigator strip shared by the left workspace sidebar and the right
/// inspector. A stock segmented picker: AppKit gives equal-width segments that
/// stretch with the pane, drops the hairlines flanking the selection, and
/// keeps the system look, animation and keyboard handling — all of which we
/// used to draw by hand.
struct SidebarNavStrip: View {
    let tabs: [SidebarNavTab]
    @Binding var selection: String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(tabs) { tab in
                Image(systemName: tab.symbol)
                    .accessibilityLabel(Text(tab.help))
                    .tag(tab.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}
