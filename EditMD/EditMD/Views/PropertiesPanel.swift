import SwiftUI
import AppKit

/// Right-inspector «Свойства» tab: YAML frontmatter as a form.
/// Simple fields commit on Enter/blur via `applyDocumentEdit`; complex fields
/// are read-only with a jump to Source.
struct PropertiesPanel: View {
    @ObservedObject var document: MarkdownDocument
    /// When set, «Открыть в Source» jumps to the field line.
    var onOpenInSource: ((Int) -> Void)? = nil

    @State private var draftScalars: [String: String] = [:]
    @State private var newTagText: [String: String] = [:]
    @State private var showAddField = false
    @State private var addKey = ""
    @State private var addType: AddFieldType = .string
    @State private var addValue = ""
    /// Tracks which scalar field currently holds focus so we commit on blur.
    @FocusState private var focusedKey: String?

    private var content: String { document.content }

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
                    emptyPrompt
                } else if fields.isEmpty {
                    emptyState("Пустой блок свойств")
                    addFieldControls
                } else {
                    ForEach(Array(fields.enumerated()), id: \.element.key) { _, field in
                        propertyRow(field)
                    }
                    addFieldControls
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, SidebarChrome.firstContentTop)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: content) { _ in
            let keys = Set(fields.map(\.key))
            draftScalars = draftScalars.filter { keys.contains($0.key) }
            newTagText = newTagText.filter { keys.contains($0.key) }
        }
        .onChange(of: focusedKey) { newFocus in
            // Commit the field that just lost focus (blur).
            for (key, draft) in draftScalars {
                if newFocus != key,
                   let field = fields.first(where: { $0.key == key }),
                   draft != field.displayValue {
                    commitScalar(field)
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func propertyRow(_ field: PropertyField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if field.kind == .complex || !field.isEditable {
                    sourceOnlyBadge
                }
                Spacer(minLength: 0)
                if field.isEditable {
                    Button {
                        removeField(field.key)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .editMDHelp("Удалить поле")
                } else if let offset = field.utf16Offset, let onOpenInSource {
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
            editor(for: field)
        }
        .padding(.vertical, 4)
    }

    private var sourceOnlyBadge: some View {
        Text("Source only")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.55)))
    }

    @ViewBuilder
    private func editor(for field: PropertyField) -> some View {
        switch field.kind {
        case .complex:
            Text(field.displayValue.isEmpty ? "—" : field.displayValue)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bool:
            Toggle("", isOn: boolBinding(for: field))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

        case .date:
            DatePicker(
                "",
                selection: dateBinding(for: field),
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.field)
            .controlSize(.small)

        case .tags, .aliases, .list:
            editableList(for: field)

        case .string, .number:
            TextField(
                field.kind == .number ? "0" : "значение",
                text: scalarDraftBinding(for: field)
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .focused($focusedKey, equals: field.key)
            .onSubmit { commitScalar(field) }
        }
    }

    private func editableList(for field: PropertyField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if field.items.isEmpty {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(field.items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 4) {
                        Text(item)
                            .font(.system(size: 11))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: SidebarChrome.wellColor))
                            )
                            .lineLimit(1)
                        Button {
                            removeListItem(field: field, at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 4) {
                TextField(
                    "добавить…",
                    text: Binding(
                        get: { newTagText[field.key] ?? "" },
                        set: { newTagText[field.key] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit { addListItem(field: field) }
                Button("＋") { addListItem(field: field) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Add field / empty

    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            Text("Нет frontmatter")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button {
                createFrontmatter()
            } label: {
                Label("Добавить свойства", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var addFieldControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showAddField {
                TextField("ключ", text: $addKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Picker("Тип", selection: $addType) {
                    ForEach(AddFieldType.allCases, id: \.self) { t in
                        Text(t.label).tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                if addType == .string || addType == .number || addType == .date {
                    TextField("значение", text: $addValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                HStack {
                    Button("Добавить") { commitAddField() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    Button("Отмена") {
                        showAddField = false
                        addKey = ""
                        addValue = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            } else {
                Button {
                    showAddField = true
                } label: {
                    Label("Поле", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    // MARK: - Bindings

    private func scalarDraftBinding(for field: PropertyField) -> Binding<String> {
        Binding(
            get: {
                if let draft = draftScalars[field.key] { return draft }
                return field.displayValue
            },
            set: { draftScalars[field.key] = $0 }
        )
    }

    private func boolBinding(for field: PropertyField) -> Binding<Bool> {
        Binding(
            get: {
                let v = field.displayValue.lowercased()
                return v == "true" || v == "yes" || v == "on"
            },
            set: { on in
                applyPlainScalar(key: field.key, value: on ? "true" : "false",
                                actionName: "Edit \(field.key)")
            }
        )
    }

    private func dateBinding(for field: PropertyField) -> Binding<Date> {
        Binding(
            get: { parseYAMLDate(field.displayValue) ?? Date() },
            set: { date in
                applyPlainScalar(key: field.key, value: formatYAMLDate(date),
                                actionName: "Edit \(field.key)")
            }
        )
    }

    // MARK: - Mutations

    private func commitScalar(_ field: PropertyField) {
        let raw = draftScalars[field.key] ?? field.displayValue
        defer { draftScalars[field.key] = nil }
        guard raw != field.displayValue else { return }
        if field.kind == .number {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard isYAMLNumber(trimmed) else {
                NSSound.beep()
                return
            }
            applyPlainScalar(key: field.key, value: trimmed,
                             actionName: "Edit \(field.key)")
        } else {
            applyScalar(key: field.key, value: raw, actionName: "Edit \(field.key)")
        }
    }

    private func addListItem(field: PropertyField) {
        let text = (newTagText[field.key] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var items = field.items
        if items.isEmpty, !field.displayValue.isEmpty, field.displayValue != "—" {
            items = [field.displayValue]
        }
        items.append(text)
        newTagText[field.key] = ""
        applyList(key: field.key, items: items, actionName: "Edit \(field.key)")
    }

    private func removeListItem(field: PropertyField, at index: Int) {
        var items = field.items
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        applyList(key: field.key, items: items, actionName: "Edit \(field.key)")
    }

    private func removeField(_ key: String) {
        guard let next = removeFrontmatterField(document: content, key: key) else {
            NSSound.beep()
            return
        }
        document.applyDocumentEdit(next, actionName: "Remove \(key)")
    }

    private func createFrontmatter() {
        guard let next = insertFrontmatterScalar(document: content, key: "title",
                                                 value: "") else {
            NSSound.beep()
            return
        }
        document.applyDocumentEdit(next, actionName: "Add Properties")
    }

    private func commitAddField() {
        let key = addKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            NSSound.beep()
            return
        }
        let next: String?
        switch addType {
        case .string:
            next = insertFrontmatterScalar(document: content, key: key,
                                           value: addValue)
        case .number:
            let v = addValue.trimmingCharacters(in: .whitespaces)
            guard isYAMLNumber(v) else { NSSound.beep(); return }
            next = insertFrontmatterScalar(document: content, key: key,
                                           value: v, plainLiteral: true)
        case .bool:
            next = insertFrontmatterScalar(document: content, key: key,
                                           value: "false", plainLiteral: true)
        case .date:
            let v = addValue.trimmingCharacters(in: .whitespaces)
            let dateStr = v.isEmpty ? formatYAMLDate(Date()) : v
            guard parseYAMLDate(dateStr) != nil else {
                NSSound.beep()
                return
            }
            next = insertFrontmatterScalar(document: content, key: key,
                                           value: dateStr, plainLiteral: true)
        case .list, .tags, .aliases:
            next = insertFrontmatterList(document: content, key: key, items: [])
        }
        guard let next else {
            NSSound.beep()
            return
        }
        document.applyDocumentEdit(next, actionName: "Add \(key)")
        showAddField = false
        addKey = ""
        addValue = ""
        addType = .string
    }

    private func applyScalar(key: String, value: String, actionName: String) {
        guard let next = replaceFrontmatterScalar(document: content, key: key,
                                                  newValue: value) else {
            NSSound.beep()
            return
        }
        document.applyDocumentEdit(next, actionName: actionName)
    }

    private func applyPlainScalar(key: String, value: String, actionName: String) {
        guard let next = replaceFrontmatterPlainScalar(document: content, key: key,
                                                       newValue: value) else {
            NSSound.beep()
            return
        }
        document.applyDocumentEdit(next, actionName: actionName)
    }

    private func applyList(key: String, items: [String], actionName: String) {
        if fields.contains(where: { $0.key == key }) {
            guard let next = replaceFrontmatterList(document: content, key: key,
                                                    items: items) else {
                NSSound.beep()
                return
            }
            document.applyDocumentEdit(next, actionName: actionName)
        } else {
            guard let next = insertFrontmatterList(document: content, key: key,
                                                   items: items) else {
                NSSound.beep()
                return
            }
            document.applyDocumentEdit(next, actionName: actionName)
        }
    }
}

// MARK: - Add-field type

private enum AddFieldType: String, CaseIterable {
    case string, number, bool, date, tags, aliases, list

    var label: String {
        switch self {
        case .string: return "Текст"
        case .number: return "Число"
        case .bool: return "Да/нет"
        case .date: return "Дата"
        case .tags: return "Теги"
        case .aliases: return "Aliases"
        case .list: return "Список"
        }
    }
}

// MARK: - Date helpers

private let yamlDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func parseYAMLDate(_ s: String) -> Date? {
    yamlDateFormatter.date(from: s)
}

private func formatYAMLDate(_ d: Date) -> String {
    yamlDateFormatter.string(from: d)
}
