import SwiftUI
import AppKit

/// Right inspector panel for document-scope UI (Outline, Info, later Links /
/// Backlinks / History / Properties). Mirrors the left `WorkspaceSidebar`
/// chrome: Xcode-style tab strip, `SidebarChrome` padding, window background.
struct InspectorSidebar: View {
    let fileURL: URL?
    let outlineContent: String
    let onJump: (Int) -> Void

    @AppStorage("inspectorTab") private var tab = "outline"
    /// Bottom filter field — filters Outline headings (and future lists).
    @State private var filterText = ""

    var body: some View {
        VStack(spacing: 0) {
            navigatorToolbar
                .padding(.horizontal, SidebarChrome.barPaddingH)
                .padding(.top, SidebarChrome.barPaddingTop)
                .padding(.bottom, SidebarChrome.barPaddingBottom)

            Group {
                switch tab {
                case "info":
                    infoStub
                default:
                    // "outline" and any unknown key fall back to Outline.
                    OutlineSidebar(content: outlineContent, filter: filterText, onJump: onJump)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Filter only (no + / eye — those are workspace-scope).
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Navigator toolbar

    private var navigatorToolbar: some View {
        HStack(spacing: 0) {
            navTabButton(id: "outline",
                         systemImage: "list.bullet.indent",
                         help: "Outline")
            navDivider
            navTabButton(id: "info",
                         systemImage: "info.circle",
                         help: "Info")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: SidebarChrome.wellColor))
        )
    }

    private var navDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
    }

    private func navTabButton(id: String, systemImage: String, help: String) -> some View {
        let selected = tab == id
        return Button {
            tab = id
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: SidebarChrome.iconButtonWidth,
                       height: SidebarChrome.iconButtonHeight)
                .background(
                    Circle()
                        .fill(selected ? Color.accentColor : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .editMDHelp(help)
    }

    // MARK: - Bottom bar (Filter only)

    private var bottomBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: SidebarChrome.wellColor))
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Info stub (full panel arrives in stage 3)

    private var infoStub: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Info")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let url = fileURL {
                Text(url.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(8)
            } else {
                Text("Нет открытого файла")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, SidebarChrome.firstContentTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
