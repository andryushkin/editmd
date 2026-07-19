import SwiftUI
import AppKit

/// Window toolbar for the document editor (agterm-style flat icon buttons).
/// Extracted from `ContentView` so format buttons and active-state styling
/// can grow without bloating the layout host (B1).
///
/// The mode switcher is NOT here — it lives pinned to the trailing edge of
/// `EditorActionStrip`, on the same line as the format tools.
struct EditorToolbar: ToolbarContent {
    @ObservedObject var editorSettings: EditorSettings
    let appearanceIsDark: Bool

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
    }
}
