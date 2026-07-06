import SwiftUI

struct ContentView: View {

    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?

    @AppStorage("editorMode") private var storedMode: String = EditorMode.visual.rawValue
    @State private var isDark: Bool = false
    @State private var theme: EditorTheme = .github
    @State private var wordCount = 0
    @State private var charCount = 0
    @State private var formatActions: FormatActions?
    @State private var lintSummary: LintSummary?
    @State private var positionStore = EditorPositionStore()

    private var mode: EditorMode { EditorMode(rawValue: storedMode) ?? .visual }

    private var modeBinding: Binding<EditorMode> {
        Binding(
            get: { EditorMode(rawValue: storedMode) ?? .visual },
            set: { storedMode = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .source:
                SourceTextView(
                    document: document,
                    theme: theme,
                    positionStore: positionStore,
                    onStatsUpdate: { w, c in wordCount = w; charCount = c },
                    onFormatActions: { actions in formatActions = actions },
                    onLintUpdate: { summary in lintSummary = summary }
                )
            case .visual:
                VisualMarkdownView(
                    document: document,
                    theme: theme,
                    fileURL: fileURL,
                    positionStore: positionStore,
                    onStatsUpdate: { w, c in wordCount = w; charCount = c },
                    onFormatActions: { actions in formatActions = actions }
                )
            case .preview:
                MarkdownPreviewView(document: document, fileURL: fileURL,
                                    positionStore: positionStore)
            }

            statusBar
        }
        .preferredColorScheme(isDark ? .dark : .light)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Mode", selection: modeBinding) {
                    ForEach(EditorMode.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .help(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
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
        .focusedSceneValue(\.formatActions, mode == .preview ? nil : formatActions)
        .focusedSceneValue(\.editorMode, modeBinding)
    }

    private var statusBar: some View {
        // Preview has no editor callbacks — count directly from the document.
        let (words, chars) = mode == .preview
            ? wordAndCharCount(in: document.content)
            : (wordCount, charCount)
        return HStack {
            if mode == .source, let summary = lintSummary,
               summary.errorCount + summary.warningCount > 0 {
                Button {
                    summary.jumpToNext()
                } label: {
                    HStack(spacing: 8) {
                        if summary.errorCount > 0 {
                            Text("✕ \(summary.errorCount)").foregroundStyle(.red)
                        }
                        if summary.warningCount > 0 {
                            Text("⚠ \(summary.warningCount)").foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Jump to the next issue")
            }
            Spacer()
            Text("\(words) words  \(chars) chars")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
