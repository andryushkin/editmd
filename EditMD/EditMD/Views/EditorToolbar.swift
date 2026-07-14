import SwiftUI
import AppKit

/// Window toolbar for the document editor (agterm-style flat icon buttons).
/// Extracted from `ContentView` so format buttons and active-state styling
/// can grow without bloating the layout host (B1).
///
/// The mode switcher is NOT here — it lives pinned to the trailing edge of
/// `EditorActionStrip`, on the same line as the format tools.
struct EditorToolbar: ToolbarContent {
    let allowsSidebar: Bool
    @Binding var sidebarVisible: Bool
    @ObservedObject var editorSettings: EditorSettings
    let appearanceIsDark: Bool

    var body: some ToolbarContent {
        if allowsSidebar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .help("Toggle Sidebar (⌃⌘S)")
            }
        }
        ToolbarItemGroup {
            Button {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            .help("Cut (⌘X)")
            Button {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .help("Paste (⌘V)")
        }
        ToolbarItem {
            Menu {
                Picker("Theme", selection: $editorSettings.general.themePreset) {
                    ForEach(EditorTheme.allPresets, id: \.id) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                }
                Divider()
                Button("Settings…") {
                    // macOS 14+ uses showSettingsWindow:; 13 uses the older
                    // showPreferencesWindow:.
                    if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }
            .help("Editor theme & settings")
        }
        ToolbarItem {
            Button {
                editorSettings.general.appearance = appearanceIsDark ? .light : .dark
            } label: {
                Label("Appearance", systemImage: appearanceIsDark ? "moon" : "sun.max")
            }
            .help(appearanceIsDark ? "Switch to light appearance" : "Switch to dark appearance")
        }
    }
}
