import SwiftUI

/// Document outline in the left sidebar: the heading tree, indented by
/// level, click = jump to the heading in the active editor (via
/// EditorPositionStore.requestJump). Re-parses debounced through
/// `.task(id:)` — SwiftUI cancels the previous task when the content
/// changes, so typing re-parses ~200 ms after the last keystroke.
struct OutlineSidebar: View {
    let content: String
    /// Case-insensitive substring match on heading titles; empty = show all.
    var filter: String = ""
    let onJump: (Int) -> Void

    @State private var items: [OutlineItem] = []

    private var visibleItems: [OutlineItem] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView {
            if items.isEmpty {
                Text("No headings")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            } else if visibleItems.isEmpty {
                Text("No matches")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleItems) { item in
                        OutlineRow(item: item) { onJump(item.markdownOffset) }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Background comes from WorkspaceSidebar (window chrome); no local fill.
        .task(id: content) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            items = markdownOutline(content)
        }
    }
}

/// One outline row: title indented by heading depth, H1/H2 semibold and
/// primary, deeper levels smaller and secondary; hover shows a soft
/// rounded wash (the row is a plain button, no default chrome).
private struct OutlineRow: View {
    let item: OutlineItem
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(item.title.isEmpty ? "(untitled)" : item.title)
                .font(.system(size: item.level == 1 ? 12 : 11,
                              weight: item.level <= 2 ? .semibold : .regular))
                .foregroundStyle(item.level <= 2 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, CGFloat(item.level - 1) * 12)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.title)
    }
}
