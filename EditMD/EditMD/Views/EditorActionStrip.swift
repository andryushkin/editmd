import SwiftUI
import AppKit

// MARK: - Action bag (all modes)

/// Closures the top action strip invokes. Modes publish what they support;
/// nil → button hidden or beeps. Shared by Source / Visual / Preview.
/// Closure bag for the action strip. Not an ObservableObject on purpose:
/// bindings are installed from `updateNSView` / format publishers; publishing
/// `objectWillChange` during a view update freezes SwiftUI.
@MainActor
final class EditorStripActions {
    var toggleBold: (() -> Void)?
    var toggleItalic: (() -> Void)?
    var toggleStrikethrough: (() -> Void)?
    var toggleCodeSpan: (() -> Void)?
    var toggleHighlight: (() -> Void)?
    /// Heading 1…3 (Title / Heading / Subheading).
    var setHeading: ((Int) -> Void)?
    /// Plain paragraph (strip structure).
    var setBody: (() -> Void)?
    /// Clear inline styles only (B4).
    var clearInlineFormatting: (() -> Void)?
    var insertDivider: (() -> Void)?
    var cycleCase: (() -> Void)?
    var toggleCodeBlock: (() -> Void)?
    var toggleBulletList: (() -> Void)?
    var toggleChecklist: (() -> Void)?
    var toggleNumberedList: (() -> Void)?
    var toggleQuote: (() -> Void)?
    var copySelection: (() -> Void)?

    // Visual-only
    var insertTable: (() -> Void)?
    var tableAddRow: (() -> Void)?
    var tableDeleteRow: (() -> Void)?
    var insertInlineFormula: (() -> Void)?
    var insertBlockFormula: (() -> Void)?

    /// Active inline formats at caret — drives accent tint on B/I/`/S (B6).
    var activeFormats: ActiveInlineFormats = ActiveInlineFormats()

    func run(_ action: (() -> Void)?) {
        guard let action else { NSSound.beep(); return }
        action()
    }
}

// MARK: - Strip UI

/// Top action pill(s) — folder-info chrome, Notes-like tool groups.
/// Always above the editor; leading inset matches the active mode's reading field.
struct EditorActionStrip: View {
    /// Closures only — not observed for UI identity (mutating them must not
    /// republish during `updateNSView` or SwiftUI freezes).
    var actions: EditorStripActions
    /// Source / Visual / Preview inset for column alignment.
    var insetH: CGFloat
    var columnWidth: CGFloat
    /// Table + formula tools (Visual only). Driven by mode, not by nil-ing
    /// closures on the actions bag.
    var showVisualExtras: Bool = false
    /// B6: tint B/I/`/S when caret is inside those styles.
    var activeFormats: ActiveInlineFormats = ActiveInlineFormats()
    /// Mode switcher — pinned to the trailing edge of the strip (the window
    /// toolbar no longer carries it).
    var mode: EditorMode
    var setEditorMode: (EditorMode) -> Void

    var body: some View {
        GeometryReader { geo in
            let lead = contentLeading(for: geo.size.width)
            HStack(alignment: .center, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    toolGroups
                        .padding(.leading, lead)
                        .padding(.trailing, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Pinned: the tools scroll under it, the switcher stays put.
                modePill
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.trailing, SidebarChrome.barPaddingH)
            .padding(.top, SidebarChrome.barPaddingTop)
            .padding(.bottom, SidebarChrome.barPaddingBottom)
        }
        .frame(height: stripHeight)
    }

    // MARK: Tool groups (scrolling)

    private var toolGroups: some View {
        HStack(alignment: .center, spacing: 8) {
                    // Inline styles
                    pill {
                        icon("bold", "Жирный (**…**)",
                             active: activeFormats.bold) { actions.run(actions.toggleBold) }
                        sep
                        icon("italic", "Курсив (*…*)",
                             active: activeFormats.italic) { actions.run(actions.toggleItalic) }
                        sep
                        icon("strikethrough", "Зачёркивание (~~…~~)",
                             active: activeFormats.strikethrough) {
                            actions.run(actions.toggleStrikethrough)
                        }
                        sep
                        labelBtn("<>", "Инлайн-код (`…`)",
                                 active: activeFormats.code) {
                            actions.run(actions.toggleCodeSpan)
                        }
                        sep
                        icon("highlighter", "Выделение (==…==)",
                             active: activeFormats.highlight) {
                            actions.run(actions.toggleHighlight)
                        }
                        sep
                        icon("doc.on.doc", "Копировать") { actions.run(actions.copySelection) }
                    }
                    // Paragraph styles (markdown-relevant)
                    pill {
                        labelBtn("H1", "Заголовок 1 (#)", active: activeFormats.headingLevel == 1) {
                            if let h = actions.setHeading { h(1) } else { NSSound.beep() }
                        }
                        sep
                        labelBtn("H2", "Заголовок 2 (##)", active: activeFormats.headingLevel == 2) {
                            if let h = actions.setHeading { h(2) } else { NSSound.beep() }
                        }
                        sep
                        labelBtn("H3", "Заголовок 3 (###)", active: activeFormats.headingLevel == 3) {
                            if let h = actions.setHeading { h(3) } else { NSSound.beep() }
                        }
                        sep
                        labelBtn("T", "Обычный текст (снять inline-разметку)") {
                            actions.run(actions.clearInlineFormatting)
                        }
                        sep
                        labelBtn("Aa", "Снять заголовок/список") {
                            actions.run(actions.setBody)
                        }
                        sep
                        labelBtn("aA", "Регистр: UPPER → lower → Capitalized") {
                            actions.run(actions.cycleCase)
                        }
                        sep
                        icon("minus", "Линия-разделитель (---)") {
                            actions.run(actions.insertDivider)
                        }
                        sep
                        icon("chevron.left.forwardslash.chevron.right", "Блок кода",
                             active: activeFormats.codeBlock) {
                            actions.run(actions.toggleCodeBlock)
                        }
                    }
                    // Lists + quote
                    pill {
                        icon("list.bullet", "Маркированный список",
                             active: activeFormats.bulletList) {
                            actions.run(actions.toggleBulletList)
                        }
                        sep
                        icon("checklist", "Чеклист", active: activeFormats.checklist) {
                            actions.run(actions.toggleChecklist)
                        }
                        sep
                        icon("list.number", "Нумерованный список",
                             active: activeFormats.numberedList) {
                            actions.run(actions.toggleNumberedList)
                        }
                        sep
                        icon("text.quote", "Цитата", active: activeFormats.quote) {
                            actions.run(actions.toggleQuote)
                        }
                    }
                    // Visual-only: table + formula insert
                    if showVisualExtras {
                        pill {
                            tableMenu
                            sep
                            formulaMenu
                        }
                    }
        }
    }

    // MARK: Mode switcher (pinned trailing)

    private var modePill: some View {
        pill {
            ForEach(Array(EditorMode.allCases.enumerated()), id: \.element.id) { index, candidate in
                if index > 0 { sep }
                icon(mode == candidate ? candidate.activeSystemImage : candidate.systemImage,
                     "\(candidate.title) (\(candidate.shortcutHint))",
                     active: mode == candidate) {
                    setEditorMode(candidate)
                }
            }
        }
        .fixedSize()
    }

    // MARK: Table menu (Visual)

    private var tableMenu: some View {
        Menu {
            Button("Вставить таблицу 3×3") { actions.run(actions.insertTable) }
            Divider()
            Button("Добавить строку") { actions.run(actions.tableAddRow) }
            Button("Удалить строку") { actions.run(actions.tableDeleteRow) }
        } label: {
            Image(systemName: "tablecells")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: SidebarChrome.iconButtonWidth,
                       height: SidebarChrome.iconButtonHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(width: SidebarChrome.iconButtonWidth, height: SidebarChrome.iconButtonHeight)
        .editMDHelp("Таблица")
    }

    // MARK: Formula menu (Visual)

    private var formulaMenu: some View {
        Menu {
            Button("Встроенная формула  $…$") { actions.run(actions.insertInlineFormula) }
            Button("Блочная формула  $$…$$") { actions.run(actions.insertBlockFormula) }
        } label: {
            Image(systemName: "function")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: SidebarChrome.iconButtonWidth,
                       height: SidebarChrome.iconButtonHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(width: SidebarChrome.iconButtonWidth, height: SidebarChrome.iconButtonHeight)
        .editMDHelp("Формула")
    }

    // MARK: Chrome

    private var stripHeight: CGFloat {
        SidebarChrome.barPaddingTop
            + SidebarChrome.barPaddingBottom
            + 8
            + SidebarChrome.iconButtonHeight
    }

    private func contentLeading(for width: CGFloat) -> CGFloat {
        guard columnWidth > 0, width > 0 else { return insetH }
        let bodyWidth = min(columnWidth, width)
        let bodyOrigin = max(0, (width - bodyWidth) / 2)
        return bodyOrigin + insetH
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: SidebarChrome.wellColor))
            )
    }

    private var sep: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
    }

    private func icon(_ systemImage: String, _ help: String,
                      active: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: SidebarChrome.iconButtonWidth,
                       height: SidebarChrome.iconButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .editMDHelp(help)
    }

    private func labelBtn(_ title: String, _ help: String,
                          active: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(minWidth: SidebarChrome.iconButtonWidth,
                       minHeight: SidebarChrome.iconButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .editMDHelp(help)
    }
}
