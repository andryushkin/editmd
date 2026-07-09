import SwiftUI

/// Lightweight source-line gutter for Preview (WKWebView has no NSRulerView).
/// Scroll is independent of the page for now; marks use the same session tracker.
struct SourceLineGutterRail: View {
    let content: String
    let dirtyLines: Set<Int>
    let settings: GutterSettings

    private var lineCount: Int {
        max(1, splitDiffLines(content).count)
    }

    var body: some View {
        if !settings.gutterVisible {
            EmptyView()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .trailing, spacing: 0) {
                    ForEach(1...lineCount, id: \.self) { n in
                        row(n)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, 4)
            }
            .frame(width: settings.showLineNumbers ? 40 : 16)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .overlay(alignment: .trailing) {
                Divider()
            }
        }
    }

    @ViewBuilder
    private func row(_ n: Int) -> some View {
        let dirty = settings.highlightChangedLines && dirtyLines.contains(n)
        Group {
            if settings.showLineNumbers {
                Text("\(n)")
                    .font(.system(size: 10, design: .monospaced))
                    .fontWeight(dirty ? .bold : .regular)
                    .foregroundStyle(dirty
                        ? Color(nsColor: settings.dirtyMarkNSColor)
                        : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(height: 15)
            } else if dirty, settings.showDirtyBulletsWhenNoNumbers {
                Circle()
                    .fill(Color(nsColor: settings.dirtyMarkNSColor))
                    .frame(width: 6, height: 6)
                    .frame(maxWidth: .infinity)
                    .frame(height: 15)
            } else {
                Color.clear.frame(height: 15)
            }
        }
    }
}
