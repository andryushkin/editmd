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
struct SidebarNavTab: Identifiable, Equatable {
    let id: String
    let systemImage: String
    /// Tooltip and VoiceOver label.
    let help: String
    /// Symbol shown while `badge > 0`. A segment leaves no room for a badge
    /// dot, so a tab with pending work swaps in a filled variant instead.
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

    /// Tooltip: the plain name, or the name plus the pending count.
    var tooltip: String {
        badge > 0 ? String(localized: "\(help) · \(badge) open") : help
    }
}

/// The navigator strip shared by the left workspace sidebar and the right
/// inspector — `NSSegmentedControl` itself, not SwiftUI's segmented picker.
/// AppKit gives the Xcode look for free: equal-width segments, hairlines that
/// vanish next to the selection, system highlight, animation and keyboard.
///
/// Wrapped rather than used through `Picker` because the SwiftUI picker keeps
/// its intrinsic width (it centers in the pane instead of filling it, no
/// `segmentDistribution` knob) and exposes no per-segment tooltip.
struct SidebarNavStrip: NSViewRepresentable {
    let tabs: [SidebarNavTab]
    @Binding var selection: String

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        // The whole point: segments split the pane width evenly and follow it
        // as the divider is dragged.
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        control.target = context.coordinator
        control.action = #selector(SidebarNavStripCoordinator.segmentChanged(_:))
        // Let SwiftUI stretch the control past its intrinsic width.
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(to: control, coordinator: context.coordinator)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        apply(to: control, coordinator: context.coordinator)
    }

    /// Fill the proposed width; keep the control's own height.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: NSSegmentedControl,
                      context: Context) -> CGSize? {
        let fitting = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? fitting.width, height: fitting.height)
    }

    func makeCoordinator() -> SidebarNavStripCoordinator {
        SidebarNavStripCoordinator()
    }

    private func apply(to control: NSSegmentedControl,
                       coordinator: SidebarNavStripCoordinator) {
        coordinator.tabIDs = tabs.map(\.id)
        coordinator.onSelect = { selection = $0 }

        if control.segmentCount != tabs.count {
            control.segmentCount = tabs.count
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        for (index, tab) in tabs.enumerated() {
            let image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.help)?
                .withSymbolConfiguration(configuration)
            if control.image(forSegment: index) !== image {
                control.setImage(image, forSegment: index)
            }
            control.setToolTip(tab.tooltip, forSegment: index)
            // Width 0 = let `fillEqually` size the segment.
            control.setWidth(0, forSegment: index)
        }
        if let selected = tabs.firstIndex(where: { $0.id == selection }) {
            if control.selectedSegment != selected {
                control.setSelected(true, forSegment: selected)
            }
        } else if control.selectedSegment != -1 {
            control.setSelected(false, forSegment: control.selectedSegment)
        }
    }
}

/// Bridges the control's target/action back to the SwiftUI binding.
final class SidebarNavStripCoordinator: NSObject {
    var tabIDs: [String] = []
    var onSelect: (String) -> Void = { _ in }

    @objc func segmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard tabIDs.indices.contains(index) else { return }
        onSelect(tabIDs[index])
    }
}
