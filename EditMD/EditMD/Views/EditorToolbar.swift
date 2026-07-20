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
        // button. A Toggle with `.button` style so macOS draws the active
        // (open) state itself — a plain `foregroundStyle` tint is often ignored
        // on toolbar SF Symbols. Disabled where no inspector pane exists.
        ToolbarItem(placement: .primaryAction) {
            // Read the sticky pref through availability so a disabled toggle
            // reads as off, not checked-grey, on folder/welcome/viewer panes.
            // Writes are inert while unavailable (the toggle is also disabled).
            Toggle(isOn: Binding(
                get: { inspectorAvailable && inspectorVisible },
                set: { if inspectorAvailable { inspectorVisible = $0 } }
            )) {
                Label("Toggle Inspector", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .help("Toggle Inspector (⌥⌘0)")
            .disabled(!inspectorAvailable)
        }
    }
}
