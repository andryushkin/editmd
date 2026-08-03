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
    /// Non-nil only while Preview is active: Edit ▸ Find then drives the
    /// Preview's JS search (WKWebView ignores the native text finder).
    @FocusedValue(\.previewFind) var previewFind

    @StateObject private var history = DocumentHistory.shared
    // Both drive the enabled state of Edit ▸ Send to Claude.
    @StateObject private var claudeService = ClaudeIDEService.shared
    @StateObject private var claudeBridge = ClaudeIDEBridge.shared

    /// Edit ▸ Find → focused NSTextView's find bar. `performTextFinderAction`
    /// reads the action from the SENDER's tag, so the menu item is the message.
    private func sendFindAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)),
                         to: nil, from: item)
    }

    /// File ▸ Open (no DocumentGroup to provide it). Loads into the main
    /// window — Lite mode applies only to Finder double-clicks.
    @MainActor private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdown, .textBundle, .pdf]
            + supportedImageContentTypes()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            AppState.shared.openInMainWindow(url.standardizedFileURL)
        }
    }

    /// File ▸ Export as PDF… — focused editor buffer (incl. unsaved/untitled).
    /// Folder-info / welcome leave `documentActions` nil, same as Save.
    @MainActor private func exportFocusedDocumentAsPDF() {
        guard let actions = documentActions else { NSSound.beep(); return }
        actions.prepareForExport?()
        // Live editor buffer — works without a path on disk.
        let content = actions.markdownContent()
        let url = actions.fileURL
        let name = url?.deletingPathExtension().lastPathComponent
            ?? String(localized: "Untitled")
        PDFExporter.export(markdown: content, suggestedName: name, fileURL: url)
    }

    /// Help ▸ Demo Markup: copy bundled KitchenSink.md to a temp file, open in
    /// a lite window — smoke-tests all three modes.
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
            // Without DocumentGroup, `replacing: .saveItem` often renders empty
            // (system still shows Close) — Save/Export go after .newItem so
            // they always appear with New/Open.
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

            // Clear the system Save slot — avoids a second empty Save group
            // above Close.
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

            // Cut/Copy/Paste/Select All stay STOCK SwiftUI items — custom
            // Buttons sending the same selectors broke ⌘X/⌘C/⌘V/⌘A inside every
            // AppKit panel (docs/architecture.md § Menus and AppKit panels).
            CommandGroup(after: .pasteboard) {
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

                    // Preview is read-only: no replace target, always the
                    // native finder (Source/Visual).
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

                // at_mentioned — only while a `claude` client is attached.
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

                // Right inspector. ⌥⌘0 mirrors Xcode; ⌥⌘1…6 stay Format ▸ Heading.
                Button(inspectorVisible?.wrappedValue == true
                       ? "Hide Inspector" : "Show Inspector") {
                    inspectorVisible?.wrappedValue.toggle()
                }
                .keyboardShortcut("0", modifiers: [.option, .command])
                .disabled(inspectorVisible == nil)

                // Shares the Settings ▸ gutter toggle; editors react live.
                Toggle("Line Numbers", isOn: Binding(
                    get: { EditorSettings.shared.gutter.showLineNumbers },
                    set: { EditorSettings.shared.gutter.showLineNumbers = $0 }
                ))
                .keyboardShortcut("l", modifiers: [.command, .shift, .option])

                Divider()

                Button("Back") {
                    AppState.shared.historyBack()
                }
                .keyboardShortcut("[")
                .disabled(!history.canGoBack)

                Button("Forward") {
                    AppState.shared.historyForward()
                }
                .keyboardShortcut("]")
                .disabled(!history.canGoForward)

                Divider()

                Button("Check Workspace Links") {
                    VaultLintReportPresenter.present()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift, .control])
            }

            // App menu under About — the non-App-Store convention. Works
            // regardless of the automatic-check switch in Settings ▸ General.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateChecker.shared.checkManually()
                }
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

        // Lite windows — one file each, sidebar-less (Lite-mode Finder route,
        // sidebar "Open in separate window").
        WindowGroup(for: URL.self) { $url in
            LiteWindowContent(url: url)
        }

        Settings {
            SettingsView()
                .longRunningOperationOverlay()
        }
    }
}

/// One lite window. Separate view so the appearance override applies at the
/// window root, same as MainWindowView.
private struct LiteWindowContent: View {
    let url: URL?
    @ObservedObject private var editorSettings = EditorSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let url, isPDFFile(url) {
                    PDFViewerHost(fileURL: url)
                } else if let url, isImageFile(url) {
                    ImageViewerHost(fileURL: url)
                } else {
                    FileEditor(url: url, allowsSidebar: false, isMain: false)
                }
            }
            // Viewer panes lack the editor status bar; still surface background
            // workspace work (index scan / vault-lint).
            if let url, isPDFFile(url) || isImageFile(url) {
                StandaloneActivityBar()
            }
        }
        .frame(minWidth: liteWindowMinWidth, minHeight: liteWindowMinHeight)
        .preferredColorScheme(editorSettings.general.appearance.colorScheme)
        .longRunningOperationOverlay()
        .background(WindowAccessor { window in
            applyWindowContentMinimum(window,
                                      width: liteWindowMinWidth,
                                      height: liteWindowMinHeight)
        })
    }
}
