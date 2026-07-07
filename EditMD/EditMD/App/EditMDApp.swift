import SwiftUI
import AppKit

@main
struct EditMDApp: App {

    @FocusedValue(\.formatActions) var actions
    @FocusedValue(\.editorMode) var editorMode
    @FocusedValue(\.sidebarVisible) var sidebarVisible
    @FocusedValue(\.splitPreview) var splitPreview

    @StateObject private var history = DocumentHistory.shared
    @Environment(\.openDocument) private var openDocument

    /// Routes an Edit ▸ Find command into the focused NSTextView's find bar.
    /// performTextFinderAction reads the action from the SENDER's tag, so the
    /// menu item itself is the message.
    private func sendFindAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)),
                         to: nil, from: item)
    }

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { configuration in
            ContentView(document: configuration.document, fileURL: configuration.fileURL)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                }
                .keyboardShortcut("z")

                Button("Redo") {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
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
                    history.goBack { url in
                        Task { try? await openDocument(at: url) }
                    }
                }
                .keyboardShortcut("[")
                .disabled(!history.canGoBack)

                Button("Forward") {
                    history.goForward { url in
                        Task { try? await openDocument(at: url) }
                    }
                }
                .keyboardShortcut("]")
                .disabled(!history.canGoForward)

                Divider()
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

        Settings {
            SettingsView()
        }
    }
}
