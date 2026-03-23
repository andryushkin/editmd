import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupFormatMenu()
    }

    private func setupFormatMenu() {
        let formatMenu = NSMenu(title: "Format")
        let bigger = NSMenuItem(
            title: "Bigger",
            action: #selector(MarkdownEditorViewController.makeFontBigger),
            keyEquivalent: "="
        )
        bigger.keyEquivalentModifierMask = .command
        let smaller = NSMenuItem(
            title: "Smaller",
            action: #selector(MarkdownEditorViewController.makeFontSmaller),
            keyEquivalent: "-"
        )
        smaller.keyEquivalentModifierMask = .command
        formatMenu.addItem(bigger)
        formatMenu.addItem(smaller)

        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        formatItem.submenu = formatMenu
        NSApp.mainMenu?.addItem(formatItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
