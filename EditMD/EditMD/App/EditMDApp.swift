import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct EditMDApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @FocusedValue(\.formatActions) var actions
    @FocusedValue(\.editorMode) var editorMode
    @FocusedValue(\.sidebarVisible) var sidebarVisible
    @FocusedValue(\.inspectorVisible) var inspectorVisible
    @FocusedValue(\.documentActions) var documentActions
    @FocusedValue(\.documentUndoActions) var documentUndoActions
    /// Non-nil only while a full Preview is the active mode (sprint 5). When
    /// present, Edit ▸ Find drives the Preview's JS search instead of the
    /// native text finder (which the WKWebView doesn't answer).
    @FocusedValue(\.previewFind) var previewFind

    @StateObject private var history = DocumentHistory.shared
    // Both drive the enabled state of Edit ▸ Send to Claude.
    @StateObject private var claudeService = ClaudeIDEService.shared
    @StateObject private var claudeBridge = ClaudeIDEBridge.shared

    /// Routes an Edit ▸ Find command into the focused NSTextView's find bar.
    /// performTextFinderAction reads the action from the SENDER's tag, so the
    /// menu item itself is the message.
    private func sendFindAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)),
                         to: nil, from: item)
    }

    /// File ▸ Open — DocumentGroup no longer provides it. Loads the chosen file
    /// into the main window (Lite mode is only about Finder double-clicks).
    @MainActor private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdown, .textBundle, .pdf]
            + supportedImageContentTypes()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            AppState.shared.openInMainWindow(url.standardizedFileURL)
        }
    }

    /// File ▸ Export as PDF… — focused editor buffer (including unsaved/untitled).
    /// Folder-info / welcome leave `documentActions` nil, same as Save.
    @MainActor private func exportFocusedDocumentAsPDF() {
        guard let actions = documentActions else { NSSound.beep(); return }
        actions.prepareForExport?()
        // Prefer live editor buffer — works without a path on disk.
        let content = actions.markdownContent()
        let url = actions.fileURL
        let name = url?.deletingPathExtension().lastPathComponent
            ?? String(localized: "Untitled")
        PDFExporter.export(markdown: content, suggestedName: name, fileURL: url)
    }

    /// Help ▸ Демо-разметка (D7): copy bundle KitchenSink.md to a temp file and
    /// open in a lite window so all three modes can be smoke-tested.
    @MainActor private func openKitchenSinkDemo() {
        guard let src = Bundle.main.url(forResource: "KitchenSink", withExtension: "md")
                ?? Bundle.main.url(forResource: "KitchenSink", withExtension: "md",
                                   subdirectory: nil)
        else {
            NSSound.beep()
            return
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditMD-KitchenSink.md")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            AppState.shared.openInSeparateWindow(dest.standardizedFileURL)
        } catch {
            NSSound.beep()
        }
    }

    var body: some Scene {
        // The single main workspace window (in-place file replacement).
        Window("EditMD", id: WindowID.main) {
            MainWindowView()
        }
        .commands {
            // Non-DocumentGroup apps: `replacing: .saveItem` is often empty in
            // the File menu (system still shows Close). Put Save/Export after
            // .newItem so they always appear with New/Open (see File menu repro).
            CommandGroup(replacing: .newItem) {
                Button("New") {
                    AppState.shared.openUntitled()
                }
                .keyboardShortcut("n")

                Button("Open…") {
                    openFilePanel()
                }
                .keyboardShortcut("o")

                Button("Open Folder…") {
                    WorkspaceModel.shared.promptAddFolder()
                }
                .keyboardShortcut("o", modifiers: [.shift, .command])

                Divider()

                Button("Welcome") {
                    AppState.shared.showWelcome()
                }
            }

            CommandGroup(after: .newItem) {
                Button("Save") {
                    documentActions?.save()
                }
                .keyboardShortcut("s")
                .disabled(documentActions == nil)

                Button("Save As…") {
                    documentActions?.saveAs()
                }
                .keyboardShortcut("s", modifiers: [.shift, .command])
                .disabled(documentActions == nil)

                Button("Export as PDF…") {
                    exportFocusedDocumentAsPDF()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                // Editor focused (file / untitled) only — not folder info or welcome.
                .disabled(documentActions == nil)

                Divider()

                Button("Commit File…") {
                    documentActions?.presentCommit?()
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(documentActions?.presentCommit == nil)

                Button("Push…") {
                    documentActions?.presentPush?()
                }
                .keyboardShortcut("p", modifiers: [.command, .option, .shift])
                .disabled(documentActions?.presentPush == nil)
            }

            // Clear system Save slot so we don't get a second empty/broken Save
            // group above Close.
            CommandGroup(replacing: .saveItem) {
                EmptyView()
            }

            CommandGroup(replacing: .undoRedo) {
                // Document-scoped stack (not NSTextView) so undo survives
                // Source ↔ Visual ↔ Preview.
                Button("Undo") {
                    documentUndoActions?.undo()
                }
                .keyboardShortcut("z")
                .disabled(documentUndoActions == nil)

                Button("Redo") {
                    documentUndoActions?.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(documentUndoActions == nil)
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x")

                Button("Copy") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c")

                Button("Paste") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v")

                Divider()

                Button("Select All") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a")

                Divider()

                Menu("Find") {
                    Button("Find…") {
                        if let previewFind {
                            previewFind.show()
                        } else {
                            sendFindAction(.showFindInterface)
                        }
                    }
                    .keyboardShortcut("f")

                    // Preview is read-only — no replace target there, so it always
                    // falls through to the native finder (Source/Visual).
                    Button("Find and Replace…") {
                        sendFindAction(.showReplaceInterface)
                    }
                    .keyboardShortcut("f", modifiers: [.option, .command])
                    .disabled(previewFind != nil)

                    Button("Find Next") {
                        if let previewFind {
                            previewFind.findNext()
                        } else {
                            sendFindAction(.nextMatch)
                        }
                    }
                    .keyboardShortcut("g")

                    Button("Find Previous") {
                        if let previewFind {
                            previewFind.findPrevious()
                        } else {
                            sendFindAction(.previousMatch)
                        }
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                    Divider()

                    Button("Use Selection for Find") {
                        if let previewFind {
                            previewFind.useSelectionForFind()
                        } else {
                            sendFindAction(.setSearchString)
                        }
                    }
                    .keyboardShortcut("e")
                }

                Divider()

                // at_mentioned — only meaningful while a `claude` client is
                // attached (there is nobody to receive it otherwise).
                Button("Send to Claude") {
                    claudeBridge.sendSelectionToClaude()
                }
                .keyboardShortcut("a", modifiers: [.control, .command])
                .disabled(!claudeBridge.hasSelection || !claudeService.isConnected)
            }

            CommandGroup(before: .toolbar) {
                ForEach(EditorMode.allCases) { mode in
                    Button(mode.title) {
                        editorMode?.wrappedValue = mode
                    }
                    .keyboardShortcut(mode.keyboardShortcutKey)
                    .disabled(editorMode == nil)
                }

                Divider()

                Button("Toggle Sidebar") {
                    sidebarVisible?.wrappedValue.toggle()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(sidebarVisible == nil)

                // Right inspector (document-scope). ⌥⌘0 mirrors Xcode's
                // Inspectors shortcut; ⌥⌘1…6 remain Format ▸ Heading.
                Button(inspectorVisible?.wrappedValue == true
                       ? "Hide Inspector" : "Show Inspector") {
                    inspectorVisible?.wrappedValue.toggle()
                }
                .keyboardShortcut("0", modifiers: [.option, .command])
                .disabled(inspectorVisible == nil)

                // D1: toggle shared with Settings ▸ gutter; editors already react (v27).
                Toggle("Line Numbers", isOn: Binding(
                    get: { EditorSettings.shared.gutter.showLineNumbers },
                    set: { EditorSettings.shared.gutter.showLineNumbers = $0 }
                ))
                .keyboardShortcut("l", modifiers: [.command, .shift, .option])

                Divider()

                Button("Back") {
                    history.goBack { url in AppState.shared.openInMainWindow(url) }
                }
                .keyboardShortcut("[")
                .disabled(!history.canGoBack)

                Button("Forward") {
                    history.goForward { url in AppState.shared.openInMainWindow(url) }
                }
                .keyboardShortcut("]")
                .disabled(!history.canGoForward)

                Divider()

                Button("Check Workspace Links") {
                    VaultLintReportPresenter.present()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift, .control])
            }

            CommandGroup(after: .help) {
                Button("Install Agent Skill…") {
                    SkillInstaller.installWithUI()
                }
                Button("Demo Markup") {
                    openKitchenSinkDemo()
                }
            }

            CommandMenu("Format") {
                Button("Bigger") {
                    actions?.makeFontBigger()
                }
                .keyboardShortcut("=")
                .disabled(!(actions?.canIncreaseFontSize ?? false))

                Button("Smaller") {
                    actions?.makeFontSmaller()
                }
                .keyboardShortcut("-")
                .disabled(!(actions?.canDecreaseFontSize ?? false))

                Divider()

                Button("Bold") {
                    actions?.toggleBold()
                }
                .keyboardShortcut("b")
                .disabled(actions == nil)

                Button("Italic") {
                    actions?.toggleItalic()
                }
                .keyboardShortcut("i")
                .disabled(actions == nil)

                Button("Strikethrough") {
                    actions?.toggleStrikethrough?()
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(actions?.toggleStrikethrough == nil)

                Button("Code Span") {
                    actions?.toggleCodeSpan?()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(actions?.toggleCodeSpan == nil)

                Button("Clear Inline Formatting") {
                    actions?.clearInlineFormatting?()
                }
                .disabled(actions?.clearInlineFormatting == nil)

                Button("Cycle Case") {
                    actions?.cycleCase?()
                }
                .disabled(actions?.cycleCase == nil)

                Button("Insert Divider") {
                    actions?.insertDivider?()
                }
                .disabled(actions?.insertDivider == nil)

                Divider()

                // ⌥⌘1…6 — plain ⌘1…⌘4 already switch the editor mode.
                Menu("Heading") {
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") {
                            actions?.setHeading?(level)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(level)")),
                                          modifiers: [.option, .command])
                        .disabled(actions?.setHeading == nil)
                    }
                }

                Divider()

                Button("Bulleted List") {
                    actions?.toggleBulletList?()
                }
                .keyboardShortcut("l")
                .disabled(actions?.toggleBulletList == nil)

                Button("Numbered List") {
                    actions?.toggleNumberedList?()
                }
                .keyboardShortcut("l", modifiers: [.option, .command])
                .disabled(actions?.toggleNumberedList == nil)

                Button("Checklist") {
                    actions?.toggleChecklist?()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(actions?.toggleChecklist == nil)

                Divider()

                Button("Quote") {
                    actions?.toggleQuote?()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(actions?.toggleQuote == nil)

                Button("Code Block") {
                    actions?.toggleCodeBlock?()
                }
                .keyboardShortcut("c", modifiers: [.option, .command])
                .disabled(actions?.toggleCodeBlock == nil)

                Divider()

                Button("Add Link…") {
                    actions?.editLink?()
                }
                .keyboardShortcut("k")
                .disabled(actions?.editLink == nil)

                Button("Add Image…") {
                    actions?.insertImage?()
                }
                .disabled(actions?.insertImage == nil)
            }
        }

        // Separate (lite) windows — one file each, sidebar-less. Opened via the
        // Lite-mode Finder route and the sidebar's "Open in separate window".
        WindowGroup(for: URL.self) { $url in
            LiteWindowContent(url: url)
        }

        Settings {
            SettingsView()
                .longRunningOperationOverlay()
        }
    }
}

/// Content of one lite window. A separate view so the appearance override
/// (Settings ▸ General) applies at the window root — same as MainWindowView.
private struct LiteWindowContent: View {
    let url: URL?
    @ObservedObject private var editorSettings = EditorSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let url, isPDFFile(url) {
                    PDFViewerHost(fileURL: url, allowsSidebar: false)
                } else if let url, isImageFile(url) {
                    ImageViewerHost(fileURL: url, allowsSidebar: false)
                } else {
                    FileEditor(url: url, allowsSidebar: false, isMain: false)
                }
            }
            // Viewer panes have no editor status bar; still surface
            // background workspace work (index scan / vault-lint).
            if let url, isPDFFile(url) || isImageFile(url) {
                StandaloneActivityBar()
            }
        }
        .preferredColorScheme(editorSettings.general.appearance.colorScheme)
        .longRunningOperationOverlay()
    }
}
