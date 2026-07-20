import SwiftUI
import AppKit

/// Trailing window-toolbar buttons shared by every pane so the set is identical
/// whether the center shows the editor, a folder card, or the welcome screen
/// (agterm-style flat icon buttons). Extracted from `ContentView` so it can be
/// hosted once by `MainChrome` (main window, all branches) and by the lite
/// window's `ContentView`.
///
/// The mode switcher is NOT here — it lives pinned to the trailing edge of
/// `EditorActionStrip`, on the same line as the format tools.
struct EditorToolbar: ToolbarContent {
    @ObservedObject var editorSettings: EditorSettings
    let appearanceIsDark: Bool
    /// Right inspector visibility (a shared `@AppStorage("inspectorVisible")`).
    @Binding var inspectorVisible: Bool
    /// The inspector only has a pane in the markdown editor; folder/welcome/
    /// viewer panes disable the toggle so the button set stays constant.
    var inspectorAvailable: Bool = true

    // The workspace sidebar toggle is provided once by `MainChrome` (main
    // window); it no longer lives per-editor here.
    var body: some ToolbarContent {
        ToolbarItem {
            Button {
                editorSettings.general.appearance = appearanceIsDark ? .light : .dark
            } label: {
                Label("Appearance", systemImage: appearanceIsDark ? "moon" : "sun.max")
            }
            .help(appearanceIsDark ? "Switch to light appearance" : "Switch to dark appearance")
        }
        // Plan 09: unified AI face (agent activity + prompt palette).
        ToolbarItem(placement: .primaryAction) {
            AgentActivityButton()
        }
        // Right inspector toggle, mirroring MainChrome's leading sidebar
        // button. Accent tint while open — same active-state cue as the editor
        // strip's toggles; disabled where no inspector pane exists.
        ToolbarItem(placement: .primaryAction) {
            Button { inspectorVisible.toggle() } label: {
                Label("Toggle Inspector", systemImage: "sidebar.right")
                    .foregroundStyle(inspectorVisible && inspectorAvailable
                                     ? Color.accentColor : Color.primary)
            }
            .help("Toggle Inspector (⌥⌘0)")
            .disabled(!inspectorAvailable)
        }
    }
}
