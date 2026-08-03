import SwiftUI
import AppKit

/// Right-inspector "Properties" tab: YAML frontmatter as a form.
/// Simple fields commit on Enter/blur via `applyDocumentEdit`; complex fields
/// are read-only with a jump to Source.
struct PropertiesPanel: View {
    @ObservedObject var document: MarkdownDocument
    /// When set, "Open in Source" jumps to the field line.
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

    private var pluginCards: [BuiltInPluginChecklistCard] {
        BuiltInPluginRegistry.checklistCards(in: content)
    }

    private var pluginDiagnostics: [BuiltInPluginConfigurationDiagnostic] {
        BuiltInPluginRegistry.configurationDiagnostics(in: content)
    }

    private var fields: [PropertyField] {
        let all = classifyFrontmatterFields(in: content)
        // The `editmd` tree is presented as plugin cards below, not as an
        // opaque "Source only" blob — same rule the Preview card used.
        guard pluginCards.isEmpty && pluginDiagnostics.isEmpty else {
            return all.filter { $0.key.lowercased() != "editmd" }
        }
        return all
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
                    emptyState(String(localized: "Empty properties block"))
                    addFieldControls
                } else {
                    ForEach(Array(fields.enumerated()), id: \.element.key) { _, field in
                        propertyRow(field)
                    }
                    addFieldControls
                }
                pluginSection
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
                // Same key→glyph heuristic as Preview frontmatter rows.
                Image(systemName: frontmatterFieldSystemImage(
                    key: field.key, value: field.displayValue))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .center)
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
                    .editMDHelp(String(localized: "Delete field"))
                } else if let offset = field.utf16Offset, let onOpenInSource {
                    Button {
                        onOpenInSource(offset)
                    } label: {
                        Text("Open in Source")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            editor(for: field)
                // Indent value under the key text, past the icon column.
                .padding(.leading, 20)
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
                field.kind == .number ? "0" : String(localized: "value"),
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
                    String(localized: "add…"),
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

    // MARK: - Plugins

    /// Cards of the active built-in plugins (multi-checkbox), the registry
    /// diagnostics for declared-but-invalid blocks, and the install menu.
    @ViewBuilder private var pluginSection: some View {
        Divider()
            .padding(.top, 6)
        Text("PLUGINS")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
        ForEach(pluginCards, id: \.descriptor.id) { card in
            PluginChecklistCardView(
                card: card,
                onEdit: { index, field, value in
                    applyPluginEdit(card: card, stateIndex: index,
                                    field: field, value: value)
                },
                onAddState: { addPluginState(card.descriptor) })
        }
        ForEach(pluginDiagnostics, id: \.descriptor.id) { diagnostic in
            pluginDiagnosticCard(diagnostic)
        }
        addPluginControls
    }

    private func pluginDiagnosticCard(
        _ diagnostic: BuiltInPluginConfigurationDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(diagnostic.descriptor.name)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("Error")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red.opacity(0.8)))
            }
            Text(diagnostic.message)
                .font(.system(size: 10))
                .foregroundStyle(.red)
            Text("Fix the plugin block in Source mode.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: SidebarChrome.wellColor))
        )
    }

    private var addPluginControls: some View {
        Menu {
            ForEach(BuiltInPluginRegistry.descriptors) { descriptor in
                let installed = BuiltInPluginRegistry
                    .declaredPluginIDs(in: content).contains(descriptor.id)
                Button {
                    installPlugin(descriptor)
                } label: {
                    Label(descriptor.name,
                          systemImage: installed ? "checkmark.circle.fill" : "plus.circle")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(installed)
            }
        } label: {
            Label("Plugin", systemImage: "plus")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .editMDHelp(String(localized: "Add a built-in plugin to this document"))
    }

    // MARK: - Add field / empty

    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            Text("No frontmatter")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button {
                createFrontmatter()
            } label: {
                Label("Add Properties", systemImage: "plus")
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
                TextField(String(localized: "key"), text: $addKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Picker("Type", selection: $addType) {
                    ForEach(AddFieldType.allCases, id: \.self) { t in
                        Text(t.label).tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                if addType == .string || addType == .number || addType == .date {
                    TextField(String(localized: "value"), text: $addValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                HStack {
                    Button("Add") { commitAddField() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    Button("Cancel") {
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
                    Label("Field", systemImage: "plus")
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

    /// Whitelisted plugin edit — same registry path the Preview card used:
    /// no ranges or YAML paths, the registry re-parses current frontmatter.
    /// Returns false when the registry refuses (the row resets its draft).
    private func applyPluginEdit(card: BuiltInPluginChecklistCard, stateIndex: Int,
                                 field: BuiltInPluginConfigurationField,
                                 value: String) -> Bool {
        guard card.states.indices.contains(stateIndex),
              let updated = BuiltInPluginRegistry.updateConfiguration(
                  in: content, pluginID: card.descriptor.id,
                  stateIndex: stateIndex, field: field, value: value,
                  expectedSource: card.states[stateIndex].source)
        else {
            NSSound.beep()
            return false
        }
        document.applyDocumentEdit(updated, actionName: "Edit Plugin Settings")
        return true
    }

    private func addPluginState(_ descriptor: BuiltInPluginDescriptor) {
        guard let updated = BuiltInPluginRegistry.addConfigurationState(
            pluginID: descriptor.id, in: content) else {
            NSSound.beep()
            return
        }
        document.applyDocumentEdit(updated, actionName: "Add Plugin State")
    }

    private func installPlugin(_ descriptor: BuiltInPluginDescriptor) {
        guard let updated = BuiltInPluginRegistry.installPlugin(
            id: descriptor.id, in: content) else {
            NSSound.beep()
            return
        }
        document.applyDocumentEdit(updated, actionName: "Add \(descriptor.name)")
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
        case .string: return String(localized: "Text")
        case .number: return String(localized: "Number")
        case .bool: return String(localized: "Yes/No")
        case .date: return String(localized: "Date")
        case .tags: return String(localized: "Tags")
        case .aliases: return "Aliases"
        case .list: return String(localized: "List")
        }
    }
}

// MARK: - Plugin cards

/// One active plugin's settings: state rows plus "+ State". The click
/// cycle in the document follows the state order in frontmatter.
private struct PluginChecklistCardView: View {
    let card: BuiltInPluginChecklistCard
    /// (stateIndex, field, value) → false when the registry refused the edit.
    let onEdit: (Int, BuiltInPluginConfigurationField, String) -> Bool
    let onAddState: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(card.descriptor.name)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("Enabled")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.green.opacity(0.75)))
            }
            ForEach(Array(card.states.enumerated()), id: \.offset) { index, state in
                PluginStateRowView(state: state) { field, value in
                    onEdit(index, field, value)
                }
                // Reset drafts whenever the committed state itself changes.
                .id(Self.rowIdentity(card: card, index: index, state: state))
            }
            Button {
                onAddState()
            } label: {
                Label("State", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Text("Changes are saved to frontmatter. The state order defines the click cycle.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: SidebarChrome.wellColor))
        )
    }

    private static func rowIdentity(card: BuiltInPluginChecklistCard, index: Int,
                                    state: BuiltInPluginTokenState) -> String {
        let icon: String
        switch state.icon {
        case .sfSymbol(let name): icon = "sf:\(name)"
        case .emoji(let value): icon = "emoji:\(value)"
        case .text(let value): icon = "text:\(value)"
        }
        return "\(card.descriptor.id)#\(index)#\(state.source)#\(state.label)#\(icon)#\(state.strikethrough)"
    }
}

private enum PluginIconKind: String, CaseIterable {
    case sf, emoji, text

    var label: String {
        switch self {
        case .sf: return "SF Symbol"
        case .emoji: return "Emoji"
        case .text: return String(localized: "Text")
        }
    }
}

private struct PluginStateRowView: View {
    let state: BuiltInPluginTokenState
    /// Commits one whitelisted field; false = refused, the draft resets.
    let onEdit: (BuiltInPluginConfigurationField, String) -> Bool

    @State private var marker: String
    @State private var label: String
    @State private var iconKind: PluginIconKind
    @State private var iconValue: String
    @FocusState private var focus: Field?

    private enum Field { case marker, label, icon }

    init(state: BuiltInPluginTokenState,
         onEdit: @escaping (BuiltInPluginConfigurationField, String) -> Bool) {
        self.state = state
        self.onEdit = onEdit
        _marker = State(initialValue: Self.marker(of: state))
        _label = State(initialValue: state.label)
        switch state.icon {
        case .sfSymbol(let name):
            _iconKind = State(initialValue: .sf)
            _iconValue = State(initialValue: name)
        case .emoji(let value):
            _iconKind = State(initialValue: .emoji)
            _iconValue = State(initialValue: value)
        case .text(let value):
            _iconKind = State(initialValue: .text)
            _iconValue = State(initialValue: value)
        }
    }

    private static func marker(of state: BuiltInPluginTokenState) -> String {
        let ns = state.source as NSString
        guard ns.length >= 3 else { return "" }
        return ns.substring(with: NSRange(location: 1, length: ns.length - 2))
    }

    private var sfSymbolWarning: String? {
        guard case .sfSymbol(let name) = state.icon,
              NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil
        else { return nil }
        return String(localized: "Unknown SF Symbol: \(name)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                iconPreview
                    .frame(width: 16, alignment: .center)
                TextField("x", text: $marker)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 32)
                    .focused($focus, equals: .marker)
                    .onSubmit { commitMarker() }
                    .editMDHelp(String(localized: "Marker: the character inside [ ]"))
                TextField(String(localized: "label"), text: $label)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($focus, equals: .label)
                    .onSubmit { commitLabel() }
            }
            HStack(spacing: 6) {
                Picker("", selection: $iconKind) {
                    ForEach(PluginIconKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .onChange(of: iconKind) { kind in
                    // Same defaults the Preview card used on a kind switch.
                    switch kind {
                    case .sf: iconValue = "circle"
                    case .emoji: iconValue = "🙂"
                    case .text: iconValue = marker
                    }
                    commitIcon()
                }
                TextField(String(localized: "icon"), text: $iconValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($focus, equals: .icon)
                    .onSubmit { commitIcon() }
                Toggle("Strike Through", isOn: strikethroughBinding)
                    .font(.system(size: 10))
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .fixedSize()
                    .editMDHelp(String(localized: "Strike through the item text in this state"))
            }
            if let warning = sfSymbolWarning {
                Text(warning)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: focus) { newFocus in
            // Commit the field that just lost focus (blur), like scalars do.
            if newFocus != .marker { commitMarker() }
            if newFocus != .label { commitLabel() }
            if newFocus != .icon { commitIcon() }
        }
    }

    @ViewBuilder private var iconPreview: some View {
        switch state.icon {
        case .sfSymbol(let name):
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                Image(systemName: name)
                    .font(.system(size: 11))
            } else {
                Text(state.source)
                    .font(.system(size: 10, design: .monospaced))
            }
        case .emoji(let value), .text(let value):
            Text(value)
                .font(.system(size: 11))
        }
    }

    private var strikethroughBinding: Binding<Bool> {
        Binding(
            get: { state.strikethrough },
            set: { _ = onEdit(.strikethrough, $0 ? "true" : "false") }
        )
    }

    private func commitMarker() {
        let committed = Self.marker(of: state)
        guard marker != committed else { return }
        if !onEdit(.marker, marker) { marker = committed }
    }

    private func commitLabel() {
        guard label != state.label else { return }
        if !onEdit(.label, label) { label = state.label }
    }

    private func commitIcon() {
        let serialized: String
        switch iconKind {
        case .sf: serialized = "sf:\(iconValue)"
        case .emoji: serialized = "emoji:\(iconValue)"
        case .text: serialized = iconValue
        }
        let committed: String
        switch state.icon {
        case .sfSymbol(let name): committed = "sf:\(name)"
        case .emoji(let value): committed = "emoji:\(value)"
        case .text(let value): committed = value
        }
        guard serialized != committed else { return }
        if !onEdit(.icon, serialized) {
            switch state.icon {
            case .sfSymbol(let name):
                iconKind = .sf
                iconValue = name
            case .emoji(let value):
                iconKind = .emoji
                iconValue = value
            case .text(let value):
                iconKind = .text
                iconValue = value
            }
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
