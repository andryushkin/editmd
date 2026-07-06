import SwiftUI

@main
struct EditMDApp: App {

    @FocusedValue(\.formatActions) var actions
    @FocusedValue(\.editorMode) var editorMode

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
            }
        }
    }
}
