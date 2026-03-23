import SwiftUI

enum EditorMode {
    case edit, preview
}

struct ContentView: View {

    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?

    @State private var mode: EditorMode = .edit
    @State private var wordCount = 0
    @State private var charCount = 0
    @State private var formatActions: FormatActions?

    var body: some View {
        VStack(spacing: 0) {
            if mode == .edit {
                MarkdownTextView(
                    document: document,
                    onStatsUpdate: { w, c in wordCount = w; charCount = c },
                    onFormatActions: { actions in formatActions = actions }
                )

                HStack {
                    Spacer()
                    Text("\(wordCount) words  \(charCount) chars")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else {
                MarkdownPreviewView(text: document.content, assetsURL: assetsURL)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                } label: {
                    Image(systemName: "scissors")
                }
                Button {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                Button {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
            }
            ToolbarItem {
                Picker("Mode", selection: $mode) {
                    Text("Edit").tag(EditorMode.edit)
                    Text("Preview").tag(EditorMode.preview)
                }
                .pickerStyle(.segmented)
            }
        }
        .focusedSceneValue(\.formatActions, formatActions)
    }

    private var assetsURL: URL? {
        guard let url = fileURL, url.pathExtension == "textbundle" else { return nil }
        return url.appendingPathComponent("assets")
    }
}
