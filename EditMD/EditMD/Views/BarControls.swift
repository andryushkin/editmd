import SwiftUI
import AppKit

// MARK: - Accessory-bar button

/// One control of an accessory bar (the strip above the editor, the folder
/// info action row, the welcome shortcuts, the sidebar bottom bars). Wraps
/// the system `.accessoryBar` style so hover shape, pressed and on-states all
/// come from AppKit — the hand-drawn capsule wells and accent tints are gone.
///
/// `active == nil` → a momentary `Button`. `active == some` → a `Toggle`
/// whose on-state macOS draws itself (bold at caret, line numbers, eye).
struct AccessoryBarButton: View {
    enum Glyph {
        case symbol(String)
        /// Text glyphs the strip uses where SF Symbols have no shape (H1, Aa).
        case text(String)
    }

    let glyph: Glyph
    let help: String
    var active: Bool? = nil
    let action: () -> Void

    var body: some View {
        Group {
            if let active {
                Toggle(isOn: Binding(get: { active }, set: { _ in action() })) {
                    label
                }
                .toggleStyle(.button)
            } else {
                Button(action: action) { label }
            }
        }
        .buttonStyle(.accessoryBar)
        .editMDHelp(help)
    }

    /// Uniform label height: a squat glyph (the divider's bare "—") otherwise
    /// shrinks the accessory backplate to a thin capsule next to full-height
    /// neighbours. Height only — a minWidth read as visibly oversized buttons.
    static let glyphMinHeight: CGFloat = 13

    @ViewBuilder private var label: some View {
        Group {
            switch glyph {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 12, weight: .medium))
            case .text(let title):
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
        }
        .frame(minHeight: Self.glyphMinHeight)
    }
}

/// A menu presented from an accessory bar, styled like its buttons.
/// `showsIndicator`: a visible chevron marks a COMPACT group (a whole tool
/// group folded into one menu); full-strip menus stay chevron-free.
struct AccessoryBarMenu<Content: View>: View {
    let glyph: AccessoryBarButton.Glyph
    let help: String
    var showsIndicator: Bool = false
    @ViewBuilder var content: Content

    init(systemImage: String, help: String, showsIndicator: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.glyph = .symbol(systemImage)
        self.help = help
        self.showsIndicator = showsIndicator
        self.content = content()
    }

    init(glyph: AccessoryBarButton.Glyph, help: String, showsIndicator: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.glyph = glyph
        self.help = help
        self.showsIndicator = showsIndicator
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Group {
                switch glyph {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 12, weight: .medium))
                case .text(let title):
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
            }
            .frame(minHeight: AccessoryBarButton.glyphMinHeight)
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .menuIndicator(.hidden)
        .fixedSize()
        // Disclosure badge OUTSIDE the Menu: `.menuIndicator(.visible)` is
        // silently dropped under this style combo, and anything composed into
        // the label beyond the first element is flattened by the AppKit
        // bridge. The corner chevron in our own view tree survives and
        // doesn't widen the measured pill.
        .overlay(alignment: .bottomTrailing) {
            if showsIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.secondary)
                    .offset(x: -1.5, y: -2.5)
                    .allowsHitTesting(false)
            }
        }
        .editMDHelp(help)
    }
}

// MARK: - Filter / search field

/// The system search field (loupe, clear button, focus ring) for the sidebar
/// filter bars and the workspace search — replaces the hand-drawn capsule
/// with a `TextField` inside. Text flows back on every keystroke.
struct FilterSearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    var controlSize: NSControl.ControlSize = .small

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.controlSize = controlSize
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        field.delegate = context.coordinator
        // Live filtering: report every keystroke, not only on Return.
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != prompt {
            field.placeholderString = prompt
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
