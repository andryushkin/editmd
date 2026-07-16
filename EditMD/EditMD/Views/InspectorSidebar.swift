import SwiftUI
import AppKit

/// Right inspector panel for document-scope UI (Outline, Info, later Links /
/// Backlinks / History / Properties). Mirrors the left `WorkspaceSidebar`
/// chrome: Xcode-style tab strip, `SidebarChrome` padding, window background.
struct InspectorSidebar: View {
    let fileURL: URL?

    @AppStorage("inspectorTab") private var tab = "outline"

    var body: some View {
        VStack(spacing: 0) {
            navigatorToolbar
                .padding(.horizontal, SidebarChrome.barPaddingH)
                .padding(.top, SidebarChrome.barPaddingTop)
                .padding(.bottom, SidebarChrome.barPaddingBottom)

            Group {
                switch tab {
                default:
                    // Stage 1: Info stub. Outline and full Info arrive in later stages.
                    infoStub
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Navigator toolbar

    private var navigatorToolbar: some View {
        HStack(spacing: 0) {
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

    private func navTabButton(id: String, systemImage: String, help: String) -> some View {
        let selected = tab == id || (tab != "info" && id == "info")
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

    // MARK: - Info stub (stage 1)

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
