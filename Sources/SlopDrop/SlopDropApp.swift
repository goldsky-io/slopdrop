import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.mainMenu = Self.makeMainMenu()
            AppModel.shared.start()
            IconStore.shared.loader = { await AppModel.shared.loadResource($0) }

            let controller = StatusController(model: AppModel.shared)
            statusController = controller
            // The system places the status item after launch, so give it a beat
            // before deciding whether it actually made it into the menu bar.
            controller.startWatchingPlacement()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindowController.shared.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.flushSeen() }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func openSettings() {
        MainActor.assumeIsolated { SettingsWindowController.shared.show() }
    }

    /// Without a main menu, key equivalents like ⌘V in the search field and
    /// ⌘W on the Settings window have nothing to dispatch through.
    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About SlopDrop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = NSApp.delegate
        app.addItem(.separator())
        app.addItem(withTitle: "Hide SlopDrop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit SlopDrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "SlopDrop"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
