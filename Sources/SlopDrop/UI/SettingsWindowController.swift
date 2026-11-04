import AppKit
import SwiftUI

/// The single Settings window. A unified toolbar gives the titlebar Raycast's
/// height, so the traffic lights sit inset over the sidebar.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    let router = SettingsRouter()
    private var window: NSWindow?

    func show(page: SettingsRouter.Page? = nil) {
        if let page { router.page = page }
        let isNew = window == nil
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        // AppKit focuses the first text field; Settings should open at rest.
        if isNew { DispatchQueue.main.async { window.makeFirstResponder(nil) } }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "SlopDrop Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "SlopDropSettings")
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 760, height: 520)
        window.delegate = self

        let hosting = NSHostingView(rootView: SettingsView(model: .shared, router: router, updater: .shared))
        hosting.sizingOptions = []
        window.contentView = hosting

        if !window.setFrameUsingName("SlopDropSettings") { window.center() }
        window.setFrameAutosaveName("SlopDropSettings")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.flushSeen()
    }
}
