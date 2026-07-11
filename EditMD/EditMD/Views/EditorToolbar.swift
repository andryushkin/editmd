import SwiftUI
import AppKit

/// Window toolbar for the document editor (agterm-style flat icon buttons).
/// Extracted from `ContentView` so format buttons and active-state styling
/// can grow without bloating the layout host (B1).
struct EditorToolbar: ToolbarContent {
    let allowsSidebar: Bool
    @Binding var sidebarVisible: Bool
    let mode: EditorMode
    let setEditorMode: (EditorMode) -> Void
    @Binding var splitPreview: Bool
    /// Shared with View menu: turning split ON while in Preview leaves Preview.
    let onToggleSplit: () -> Void
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
        ToolbarItemGroup(placement: .navigation) {
            ForEach(EditorMode.allCases) { candidate in
                Button {
                    setEditorMode(candidate)
                } label: {
                    Label(candidate.title,
                          systemImage: mode == candidate
                              ? candidate.activeSystemImage
                              : candidate.systemImage)
                        .foregroundStyle(mode == candidate ? Color.accentColor : Color.primary)
                }
                .help("\(candidate.title) (\(candidate.shortcutHint))")
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
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy (⌘C)")
            Button {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .help("Paste (⌘V)")
        }
        ToolbarItem {
            Button {
                onToggleSplit()
            } label: {
                Label("Split Preview",
                      systemImage: splitPreview ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            }
            .help(splitPreview ? "Hide preview pane (⌥⌘P)" : "Show preview pane (⌥⌘P)")
        }
        ToolbarItem {
            Menu {
                Picker("Theme", selection: $editorSettings.general.themePreset) {
                    Text("System").tag("system")
                    Text("GitHub").tag("github")
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
