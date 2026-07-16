import SwiftUI
import AppKit

/// Right-inspector «Свойства» tab: frontmatter as a form. Stage 3 is read-only
/// listing (including complex Source-only fields); stage 4 adds editing.
struct PropertiesPanel: View {
    let content: String
    /// When set, «Открыть в Source» jumps to the field line.
    var onOpenInSource: ((Int) -> Void)? = nil

    private var fields: [PropertyField] {
        classifyFrontmatterFields(in: content)
    }

    private var hasFrontmatter: Bool {
        frontmatterRange(in: content) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !hasFrontmatter {
                    emptyState("Нет frontmatter")
                } else if fields.isEmpty {
                    emptyState("Пустой блок свойств")
                } else {
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                        propertyRow(field)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, SidebarChrome.firstContentTop)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func propertyRow(_ field: PropertyField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(field.key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if field.kind == .complex || !field.isEditable {
                    Text("Source only")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.55)))
                }
                Spacer(minLength: 0)
                if (field.kind == .complex || !field.isEditable),
                   let offset = field.utf16Offset,
                   let onOpenInSource {
                    Button {
                        onOpenInSource(offset)
                    } label: {
                        Text("Открыть в Source")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            valueView(field)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func valueView(_ field: PropertyField) -> some View {
        if field.kind == .tags || field.kind == .aliases || field.kind == .list {
            if field.items.isEmpty {
                Text(field.displayValue.isEmpty ? "—" : field.displayValue)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                FlowChips(items: field.items)
            }
        } else {
            Text(field.displayValue.isEmpty ? "—" : field.displayValue)
                .font(.system(size: 12))
                .foregroundStyle(field.isEditable ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }
}

// MARK: - Chip flow (read-only)

/// Simple wrapping chip row without external layout deps.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        // LazyVGrid keeps layout cheap and avoids a custom flow layout for now.
        let columns = [GridItem(.adaptive(minimum: 48), spacing: 4)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.system(size: 11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: SidebarChrome.wellColor))
                    )
                    .lineLimit(1)
            }
        }
    }
}
