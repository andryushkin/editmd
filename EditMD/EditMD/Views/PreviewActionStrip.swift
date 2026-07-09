import SwiftUI
import AppKit

/// Holds Preview toolbar closures that the WKWebView coordinator installs on
/// appear. The strip calls these; without a live preview they no-op + beep.
@MainActor
final class PreviewToolbarActions: ObservableObject {
    var copySelection: (() -> Void)?
    var toggleHighlight: (() -> Void)?
    var toggleStrikethrough: (() -> Void)?

    func copy() {
        guard let copySelection else { NSSound.beep(); return }
        copySelection()
    }

    func highlight() {
        guard let toggleHighlight else { NSSound.beep(); return }
        toggleHighlight()
    }

    func strikethrough() {
        guard let toggleStrikethrough else { NSSound.beep(); return }
        toggleStrikethrough()
    }
}

/// Top action pill for full Preview mode — same chrome as the folder-info
/// strip (capsule well + icon buttons + AppKit tooltips).
struct PreviewActionStrip: View {
    @ObservedObject var actions: PreviewToolbarActions
    @ObservedObject private var editorSettings = EditorSettings.shared

    var body: some View {
        // Match previewHTMLPage layout: body is max-width = columnWidth,
        // margin: 0 auto, padding-left/right = insetH. Without GeometryReader
        // the pill only saw insetH and sat on the window edge while the
        // reading column was centered.
        GeometryReader { geo in
            let lead = contentLeading(for: geo.size.width)
            HStack(alignment: .center, spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(Array(allButtons.enumerated()), id: \.offset) { index, button in
                        if index > 0 { pillSeparator }
                        iconButton(button.systemImage, button.help, action: button.run)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: SidebarChrome.wellColor))
                )
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, lead)
            .padding(.trailing, lead)
            .padding(.top, SidebarChrome.barPaddingTop)
            .padding(.bottom, SidebarChrome.barPaddingBottom)
        }
        .frame(height: stripHeight)
    }

    /// Capsule row + chrome padding — GeometryReader must not expand vertically.
    private var stripHeight: CGFloat {
        SidebarChrome.barPaddingTop
            + SidebarChrome.barPaddingBottom
            + 8 // capsule vertical padding (4 + 4)
            + SidebarChrome.iconButtonHeight
    }

    /// Left edge of the Preview text field — same formula as the HTML body.
    private func contentLeading(for width: CGFloat) -> CGFloat {
        let inset = editorSettings.preview.insetH
        let column = editorSettings.preview.columnWidth
        guard column > 0, width > 0 else { return inset }
        let bodyWidth = min(column, width)
        let bodyOrigin = max(0, (width - bodyWidth) / 2)
        return bodyOrigin + inset
    }

    private var allButtons: [(systemImage: String, help: String, run: () -> Void)] {
        [
            ("highlighter", "Выделение (== … ==)", { actions.highlight() }),
            ("strikethrough", "Зачёркивание (~~ … ~~)", { actions.strikethrough() }),
            ("doc.on.doc", "Копировать выделение", { actions.copy() }),
        ]
    }

    private var pillSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
    }

    private func iconButton(_ systemImage: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: SidebarChrome.iconButtonWidth,
                       height: SidebarChrome.iconButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .editMDHelp(help)
    }
}
