import SwiftUI
import AppKit

@main
struct EditMDApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @FocusedValue(\.formatActions) var actions
    @FocusedValue(\.editorMode) var editorMode
    @FocusedValue(\.sidebarVisible) var sidebarVisible
    @FocusedValue(\.splitPreview) var splitPreview
    @FocusedValue(\.documentActions) var documentActions
    @FocusedValue(\.documentUndoActions) var documentUndoActions

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
        panel.allowedContentTypes = [.markdown, .textBundle]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            AppState.shared.openInMainWindow(url.standardizedFileURL)
        }
    }

    var body: some Scene {
        // The single main workspace window (in-place file replacement).
        Window("EditMD", id: WindowID.main) {
            MainWindowView()
        }
        .commands {
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

            CommandGroup(replacing: .saveItem) {
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
                        sendFindAction(.showFindInterface)
                    }
                    .keyboardShortcut("f")

                    Button("Find and Replace…") {
                        sendFindAction(.showReplaceInterface)
                    }
                    .keyboardShortcut("f", modifiers: [.option, .command])

                    Button("Find Next") {
                        sendFindAction(.nextMatch)
                    }
                    .keyboardShortcut("g")

                    Button("Find Previous") {
                        sendFindAction(.previousMatch)
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                    Divider()

                    Button("Use Selection for Find") {
                        sendFindAction(.setSearchString)
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

                Button(splitPreview?.wrappedValue == true
                    ? "Hide Preview Pane" : "Show Preview Pane") {
                    splitPreview?.wrappedValue.toggle()
                }
                .keyboardShortcut("p", modifiers: [.option, .command])
                .disabled(splitPreview == nil)

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
            }

            CommandGroup(after: .help) {
                Button("Install Agent Skill…") {
                    SkillInstaller.installWithUI()
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

                Divider()

                // ⌥⌘1…6 — plain ⌘1/⌘2/⌘3 already switch the editor mode.
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
            }
        }

        // Separate (lite) windows — one file each, sidebar-less. Opened via the
        // Lite-mode Finder route and the sidebar's "Open in separate window".
        WindowGroup(for: URL.self) { $url in
            FileEditor(url: url, allowsSidebar: false, isMain: false)
        }

        Settings {
            SettingsView()
        }
    }
}
