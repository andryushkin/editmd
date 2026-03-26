import SwiftUI

struct ContentView: View {

    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?

    @State private var isDark: Bool = false
    @State private var theme: EditorTheme = .github
    @State private var wordCount = 0
    @State private var charCount = 0
    @State private var formatActions: FormatActions?

    var body: some View {
        VStack(spacing: 0) {
            MarkdownTextView(
                document: document,
                theme: theme,
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
        }
        .preferredColorScheme(isDark ? .dark : .light)
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
                Menu {
                    Button("System")      { theme = .system }
                    Button("Comfortable") { theme = .comfortable }
                    Button("GitHub")      { theme = .github }
                } label: {
                    Image(systemName: "paintpalette")
                }
            }
            ToolbarItem {
                Button {
                    isDark.toggle()
                } label: {
                    Image(systemName: isDark ? "moon" : "sun.max")
                }
            }
        }
        .focusedSceneValue(\.formatActions, formatActions)
    }
}
