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

    /// Inner padding of the navigator capsule and the metrics of the hairline
    /// dividers between its buttons. Kept here (not as literals at the call
    /// site) because the pane's minimum width is derived from them.
    static let navPillPaddingH: CGFloat = 5
    static let navDividerWidth: CGFloat = 1
    static let navDividerPaddingH: CGFloat = 3

    /// Width the navigator capsule needs to show `tabs` buttons in full.
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

    /// Selection pill inside the navigator capsule. A capsule (not a circle)
    /// because the buttons stretch with the pane — at the floor width it is a
    /// circle, on a wide pane it grows into an Xcode-style pill.
    static let navSelectionShape = Capsule(style: .continuous)

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

/// One tab of a sidebar navigator capsule (left workspace, right inspector).
/// The button stretches with the pane like Xcode's navigator strip: at the
/// pane's floor width it is exactly `iconButtonWidth`, wider panes share the
/// slack equally between the tabs.
struct SidebarNavTabButton: View {
    let systemImage: String
    let help: String
    let selected: Bool
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                // Overlay before the stretching frame: the dot tracks the
                // glyph, not the far edge of a wide button.
                .overlay(alignment: .topTrailing) {
                    if badge > 0 && !selected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 5, y: -3)
                    }
                }
                .frame(minWidth: SidebarChrome.iconButtonWidth,
                       maxWidth: .infinity,
                       minHeight: SidebarChrome.iconButtonHeight,
                       maxHeight: SidebarChrome.iconButtonHeight)
                .background(
                    SidebarChrome.navSelectionShape
                        .fill(selected ? Color.accentColor : Color.clear)
                )
                .contentShape(SidebarChrome.navSelectionShape)
        }
        .buttonStyle(.plain)
        .editMDHelp(badge > 0 ? String(localized: "\(help) · \(badge) open") : help)
    }
}

/// Xcode-style hairline between navigator modes.
struct SidebarNavDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: SidebarChrome.navDividerWidth, height: 14)
            .padding(.horizontal, SidebarChrome.navDividerPaddingH)
    }
}
