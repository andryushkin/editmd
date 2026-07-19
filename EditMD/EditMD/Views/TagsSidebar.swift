import SwiftUI

/// Sidebar tab: frontmatter tags across workspace files (D11).
/// Only YAML `tags:` (flow/block list) — inline `#tags` deferred.
struct TagsSidebar: View {
    @ObservedObject var workspace: WorkspaceModel
    let filter: String
    let onOpen: (URL) -> Void

    @State private var expanded = Set<String>()

    private var query: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tags: [(tag: String, files: [URL])] {
        let index = workspace.tagIndex
        let filtered = index.filter { tag, _ in
            query.isEmpty || tag.localizedCaseInsensitiveContains(query)
        }
        return filtered
            .map { ($0.key, $0.value.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                    == .orderedAscending
            }) }
            .sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
    }

    var body: some View {
        // Touch epoch so scans refresh after New File/Folder.
        let _ = workspace.contentEpoch
        let rows = tags
        Group {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(query.isEmpty
                         ? String(localized: "No frontmatter tags\nin the workspace")
                         : String(localized: "No matches"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows, id: \.tag) { row in
                            tagRow(row.tag, files: row.files)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .onAppear { workspace.ensureTagIndex() }
        .onChange(of: workspace.contentEpoch) { _ in workspace.ensureTagIndex() }
        .onChange(of: workspace.workspaces) { _ in workspace.ensureTagIndex() }
    }

    @ViewBuilder private func tagRow(_ tag: String, files: [URL]) -> some View {
        let isOpen = expanded.contains(tag)
        Button {
            if isOpen { expanded.remove(tag) } else { expanded.insert(tag) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Image(systemName: "tag")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(tag)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(files.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen {
            ForEach(files, id: \.self) { url in
                Button {
                    onOpen(url)
                } label: {
                    HStack(spacing: 6) {
                        Spacer().frame(width: 20)
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Scan helpers (pure, off-main)

// `frontmatterTags` / `scanWorkspaceTags` moved to Editor/TagScan.swift
// (pure — shared with the offline editmdctl engine).
