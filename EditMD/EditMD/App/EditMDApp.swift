import SwiftUI

@main
struct EditMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Text("EditMD Settings")
                .frame(width: 300, height: 200)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") {
                    NSDocumentController.shared.newDocument(nil)
                }
                .keyboardShortcut("n")

                Button("Open…") {
                    NSDocumentController.shared.beginOpenPanel { urls in
                        guard let urls else { return }
                        for url in urls {
                            NSDocumentController.shared.openDocument(
                                withContentsOf: url, display: true
                            ) { _, _, _ in }
                        }
                    }
                }
                .keyboardShortcut("o")
            }

            CommandGroup(after: .newItem) {
                Divider()
                Button("Close") {
                    NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("w")

                Button("Save") {
                    NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s")

                Button("Save As…") {
                    NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

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

            CommandMenu("Format") {
                Button("Bigger") {
                    NSApp.sendAction(
                        #selector(MarkdownEditorViewController.makeFontBigger),
                        to: nil, from: nil)
                }
                .keyboardShortcut("=")

                Button("Smaller") {
                    NSApp.sendAction(
                        #selector(MarkdownEditorViewController.makeFontSmaller),
                        to: nil, from: nil)
                }
                .keyboardShortcut("-")

                Divider()

                Button("Bold") {
                    NSApp.sendAction(
                        #selector(MarkdownEditorViewController.toggleBold),
                        to: nil, from: nil)
                }
                .keyboardShortcut("b")

                Button("Italic") {
                    NSApp.sendAction(
                        #selector(MarkdownEditorViewController.toggleItalic),
                        to: nil, from: nil)
                }
                .keyboardShortcut("i")
            }
        }
    }
}
