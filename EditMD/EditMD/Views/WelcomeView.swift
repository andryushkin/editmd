import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Main-window host (welcome)

/// Main-window content when nothing is open: center pane = app welcome
/// (Zed-style home). The workspace sidebar + its toggle are provided by
/// `MainChrome`, so this host renders only the welcome card.
struct WelcomeHost: View {
    var body: some View {
        WelcomeCard()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WindowAccessor { window in
                window.representedURL = nil
                window.title = "EditMD"
            })
    }
}

// MARK: - Welcome card

/// Zed-like home: app identity, get-started actions, recent workspaces / files.
/// Margins follow Settings ▸ Preview (insetH / insetV / columnWidth) so the
/// reading field matches Preview; top action strip matches folder-info chrome.
struct WelcomeCard: View {
    @ObservedObject private var workspace = WorkspaceModel.shared
    @ObservedObject private var history = DocumentHistory.shared
    @ObservedObject private var editorSettings = EditorSettings.shared

    private var preview: ModeSettings { editorSettings.preview }

    /// Horizontal page padding (Preview insetH). Column centering applied in
    /// `contentLeading(for:)` when Preview column width is on.
    private var insetH: CGFloat { preview.insetH }
    /// Top/bottom page padding — same as Preview body padding (insetV).
    private var insetV: CGFloat { preview.insetV }
    private var columnWidth: CGFloat { preview.columnWidth }

    /// Optical nudge pulling only the bold title left of the content column —
    /// large glyphs read as indented next to the subtitle otherwise.
    private let titleOpticalNudge: CGFloat = -4

    private var previewH1Size: CGFloat {
        preview.fontSize * preview.elements.h1.sizeScale
    }

    private var titleFont: Font {
        let weight = (preview.elements.h1.weight ?? .bold).swiftUIWeight
        let family = preview.fontFamily
        if !family.isEmpty {
            return .custom(family, size: previewH1Size).weight(weight)
        }
        return .system(size: previewH1Size, weight: weight)
    }

    /// Same formula as `EditorActionStrip` / Preview column centering.
    private func contentLeading(for width: CGFloat) -> CGFloat {
        guard width > 0 else { return insetH }
        // Preview column on → honor it (match Preview). Off → fall back to a cap
        // so rows don't stretch edge-to-edge.
        let cap = columnWidth > 0 ? columnWidth : SidebarChrome.maxReadingWidth
        let bodyWidth = min(cap, width)
        let bodyOrigin = max(0, (width - bodyWidth) / 2)
        return bodyOrigin + insetH
    }

    private var stripHeight: CGFloat {
        SidebarChrome.barPaddingTop
            + SidebarChrome.barPaddingBottom
            + 8
            + SidebarChrome.iconButtonHeight
    }

    /// Recent rows: workspaces first, then history files not already covered
    /// (session visits). Capped for a clean home screen.
    private var recentItems: [WelcomeRecentItem] {
        var items: [WelcomeRecentItem] = []
        var seen = Set<String>()

        for ws in workspace.workspaces {
            let path = ws.url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            items.append(.workspace(ws.url, displayName: ws.name))
        }

        // Session history newest-first, skip folders already listed as workspaces.
        for url in history.entries.reversed().map(\.url) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            if AppState.isFolder(url) {
                items.append(.folder(url))
            } else {
                items.append(.file(url))
            }
            if items.count >= 12 { break }
        }

        // Pinned loose files that never hit history this session.
        for path in workspace.pinnedLoosePaths {
            guard !seen.contains(path) else { continue }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            seen.insert(path)
            items.append(.file(url))
            if items.count >= 12 { break }
        }

        return items
    }

    var body: some View {
        // Same shell as FolderInfoCard: chrome strip on window bg, page below.
        VStack(spacing: 0) {
            actionStrip
            GeometryReader { geo in
                let lead = contentLeading(for: geo.size.width)
                let padBottom = max(64, insetV)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        getStarted
                        if !recentItems.isEmpty {
                            recentSection
                        }
                        Spacer(minLength: 0)
                    }
                    // Preview reading field: H = insetH (+ column center), V = insetV.
                    .padding(.leading, lead)
                    .padding(.trailing, lead)
                    .padding(.top, insetV)
                    .padding(.bottom, padBottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Action strip (folder-info chrome)

    private var actionStrip: some View {
        GeometryReader { geo in
            let lead = contentLeading(for: geo.size.width)
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: 0) {
                    iconButton("doc.badge.plus", String(localized: "New File (⌘N)")) {
                        AppState.shared.openUntitled()
                    }
                    pillSeparator
                    iconButton("doc", String(localized: "Open File… (⌘O)"), action: openFilePanel)
                    pillSeparator
                    iconButton("folder.badge.plus", String(localized: "Open Folder… (⇧⌘O)"),
                               action: openFolderPanel)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: SidebarChrome.wellColor))
                )
                Spacer(minLength: 0)
            }
            .padding(.leading, lead)
            .padding(.trailing, lead)
            .padding(.top, SidebarChrome.barPaddingTop)
            .padding(.bottom, SidebarChrome.barPaddingBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: stripHeight)
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

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            appIcon
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to EditMD")
                    .font(titleFont)
                    .lineLimit(1)
                    .padding(.leading, titleOpticalNudge)
                Text("Markdown editor for your vault")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        let icon = NSApp.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        } else {
            Image(systemName: "doc.richtext")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
        }
    }

    // MARK: Get started

    private var getStarted: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Get Started")
            VStack(spacing: 0) {
                actionRow(systemImage: "doc.badge.plus",
                          title: "New File",
                          shortcut: "⌘N",
                          action: { AppState.shared.openUntitled() })
                rowDivider
                actionRow(systemImage: "doc",
                          title: "Open File…",
                          shortcut: "⌘O",
                          action: openFilePanel)
                rowDivider
                actionRow(systemImage: "folder.badge.plus",
                          title: "Open Folder…",
                          shortcut: "⇧⌘O",
                          action: openFolderPanel)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Recent")
            VStack(spacing: 0) {
                ForEach(Array(recentItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { rowDivider }
                    recentRow(item, index: index)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func recentRow(_ item: WelcomeRecentItem, index: Int) -> some View {
        let row = Button {
            AppState.shared.openInMainWindow(item.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
                    .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        // ⌘1…⌘9 open the first nine recents (Zed-style); skip for the rest.
        if index < 9, let ch = "\(index + 1)".first {
            row.keyboardShortcut(KeyEquivalent(ch), modifiers: .command)
        } else {
            row
        }
    }

    // MARK: Shared chrome

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }

    private func actionRow(systemImage: String, title: String, shortcut: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(shortcut)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.55))
            .frame(height: 0.5)
            .padding(.leading, 48)
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdown, .textBundle, .pdf]
            + supportedImageContentTypes()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            AppState.shared.openInMainWindow(url.standardizedFileURL)
        }
    }

    /// Adopt the folder as a workspace and open its card (Zed “Open Project”).
    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let std = url.standardizedFileURL
            WorkspaceModel.shared.addWorkspace(std)
            AppState.shared.openInMainWindow(std)
        }
    }
}

// MARK: - Recent item model

private enum WelcomeRecentItem: Identifiable {
    case workspace(URL, displayName: String)
    case folder(URL)
    case file(URL)

    var id: String {
        switch self {
        case .workspace(let u, _): return "ws:" + u.path
        case .folder(let u): return "dir:" + u.path
        case .file(let u): return "file:" + u.path
        }
    }

    var url: URL {
        switch self {
        case .workspace(let u, _), .folder(let u), .file(let u): return u
        }
    }

    var isFolder: Bool {
        switch self {
        case .workspace, .folder: return true
        case .file: return false
        }
    }

    var systemImage: String {
        switch self {
        case .workspace, .folder: return "folder.fill"
        case .file(let url): return sidebarFileIcon(for: url)
        }
    }

    var title: String {
        switch self {
        case .workspace(_, let displayName): return displayName
        case .folder(let url), .file(let url): return url.lastPathComponent
        }
    }

    var subtitle: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
