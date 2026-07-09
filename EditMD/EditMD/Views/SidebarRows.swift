import SwiftUI

// MARK: - Tree layout

/// Shared metrics so folder headers and file rows at the same depth line up:
/// leading indent → fixed chevron column (real or empty) → icon → name.
enum SidebarTree {
    static let indentStep: CGFloat = 14
    static let chevronWidth: CGFloat = 10
    static let rowSpacing: CGFloat = 6
}

// MARK: - File row

/// One file row: doc icon, name (+ optional path subtitle), active tint, hover
/// wash, and a trailing action (hide / unhide / pin). Shared by the sidebar
/// and the folder info card.
struct FileRow: View {
    /// Per-row trailing control.
    /// - `hide`: eye.slash on hover → remove from normal list
    /// - `unhide`: eye always visible (review mode / hidden section) → restore
    enum Trailing: Equatable { case hide, unhide, pin(Bool), none }

    let name: String
    var subtitle: String?
    let isActive: Bool
    /// Hidden file shown in review mode — soften label, keep eye button crisp.
    var dimmed = false
    var depth: Int = 0
    let trailing: Trailing
    let onTap: () -> Void
    var onTrailing: () -> Void = {}

    @State private var hovering = false

    private var indent: CGFloat { CGFloat(depth) * SidebarTree.indentStep }

    var body: some View {
        HStack(spacing: SidebarTree.rowSpacing) {
            if indent > 0 { Spacer().frame(width: indent) }
            // Reserve the chevron column so file icons align with folder icons.
            if depth > 0 {
                Color.clear.frame(width: SidebarTree.chevronWidth, height: 1)
            }
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .opacity(dimmed ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive
                                     ? AnyShapeStyle(Color.accentColor)
                                     : (dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            trailingButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                      : (hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var trailingButton: some View {
        switch trailing {
        case .hide:
            if hovering {
                iconButton("eye.slash", "Скрыть из списка", accent: false)
            }
        case .unhide:
            iconButton("eye", "Вернуть в список", accent: true)
        case .pin(let pinned):
            if pinned || hovering {
                iconButton(pinned ? "pin.fill" : "pin",
                           pinned ? "Открепить" : "Закрепить",
                           accent: pinned)
            }
        case .none:
            EmptyView()
        }
    }

    private func iconButton(_ systemName: String, _ help: String, accent: Bool) -> some View {
        Button(action: onTrailing) {
            Image(systemName: systemName).font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent ? Color.accentColor : Color.secondary)
        .editMDHelp(help)
    }
}

// MARK: - Folder row (info card / optional lists)

/// Folder row without hide: icon + name; tap opens the folder card.
struct FolderRow: View {
    let name: String
    var isActive: Bool = false
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: SidebarTree.rowSpacing) {
            Image(systemName: isActive ? "folder.fill" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            Text(name)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                      : (hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}
