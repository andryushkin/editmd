import SwiftUI

// MARK: - Model

/// ⌘F search state for a full Preview window (sprint 5). Highlighting and
/// navigation happen JS-side in the WKWebView; this holds the incremental
/// query and the match tally the page reports back. One instance per
/// `ContentView`, handed to `MarkdownPreviewView` and published as a focused
/// value so the Edit ▸ Find menu can drive it while Preview is the active mode.
@MainActor
final class PreviewFindModel: ObservableObject {
    /// Whether the find bar is on screen.
    @Published var isActive = false
    /// The live query (bound to the text field).
    @Published var query = ""
    /// Total matches in the rendered page.
    @Published private(set) var matchCount = 0
    /// 1-based index of the current match; 0 when there are none.
    @Published private(set) var currentIndex = 0
    /// Bumped whenever the field should (re)take focus (⌘F while already open).
    @Published var focusRequest = 0

    /// Installed by the Preview coordinator while a web view is live, cleared
    /// to nil when Preview goes away. The bar/menu invoke these; the
    /// coordinator runs the JS and calls `report(...)` back with the tally.
    var runSearch: ((String) -> Void)?
    var stepMatch: ((Int) -> Void)?
    var clearSearch: (() -> Void)?
    /// Current WebKit selection text (for ⌘E "Use Selection for Find").
    var currentSelection: (() -> String?)?

    /// The page answered a search/step with a fresh tally.
    func report(count: Int, index: Int) {
        matchCount = count
        currentIndex = index
    }

    /// ⌘F: show the bar (or refocus it) and re-run any existing query.
    func activate() {
        isActive = true
        focusRequest &+= 1
        if !query.isEmpty { runSearch?(query) }
    }

    /// ⌘E: seed the query from the current selection, then show + search.
    func useSelectionForFind() {
        if let selection = currentSelection?()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !selection.isEmpty {
            isActive = true
            focusRequest &+= 1
            setQuery(selection)
        } else {
            activate()
        }
    }

    /// Incremental search: empty clears highlights; otherwise search live.
    func setQuery(_ text: String) {
        query = text
        if text.isEmpty {
            matchCount = 0
            currentIndex = 0
            clearSearch?()
        } else {
            runSearch?(text)
        }
    }

    func next() {
        guard matchCount > 0 else { return }
        stepMatch?(1)
    }

    func previous() {
        guard matchCount > 0 else { return }
        stepMatch?(-1)
    }

    /// Escape / mode switch: hide the bar and drop the highlights. The query
    /// string is kept so reopening restores the last search (native behavior).
    func close() {
        guard isActive || matchCount > 0 else { return }
        isActive = false
        matchCount = 0
        currentIndex = 0
        clearSearch?()
    }
}

// MARK: - Focused value bridge (Edit ▸ Find menu → active Preview)

/// Published by `ContentView` only while `mode == .preview`, so the Find menu
/// can tell a focused Preview from a Source/Visual editor (which keep the
/// native `NSTextFinder` path).
struct PreviewFindActions {
    var show: () -> Void
    var findNext: () -> Void
    var findPrevious: () -> Void
    var useSelectionForFind: () -> Void
}

struct PreviewFindKey: FocusedValueKey {
    typealias Value = PreviewFindActions
}

extension FocusedValues {
    var previewFind: PreviewFindActions? {
        get { self[PreviewFindKey.self] }
        set { self[PreviewFindKey.self] = newValue }
    }
}

// MARK: - Bar

/// Compact find bar overlaid at the top-trailing corner of the Preview pane.
/// Enter jumps to the next match; the chevrons and ⌘G / ⌘⇧G do next/previous.
struct PreviewFindBar: View {
    @ObservedObject var model: PreviewFindModel
    @FocusState private var fieldFocused: Bool

    private var countLabel: String {
        if model.query.isEmpty { return "" }
        if model.matchCount == 0 { return String(localized: "Not found") }
        return String(localized: "\(model.currentIndex) of \(model.matchCount)")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField(
                "Find",
                text: Binding(get: { model.query },
                              set: { model.setQuery($0) })
            )
            .textFieldStyle(.plain)
            .focused($fieldFocused)
            .frame(minWidth: 150, maxWidth: 220)
            .onSubmit { model.next() }

            if !countLabel.isEmpty {
                Text(countLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Divider().frame(height: 16)

            Button {
                model.previous()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(model.matchCount == 0)
            .help("Find Previous (⌘⇧G)")

            Button {
                model.next()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(model.matchCount == 0)
            .help("Find Next (⌘G)")

            Button {
                model.close()
            } label: {
                Image(systemName: "xmark")
            }
            .keyboardShortcut(.cancelAction)
            .help("Close (⎋)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusRequest) { _ in fieldFocused = true }
    }
}
