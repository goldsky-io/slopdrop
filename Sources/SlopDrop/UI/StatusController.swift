import AppKit
import Combine

/// Owns the menu bar item: a native menu with the essentials, and Settings for
/// everything else. Some systems never place a new status item — a full menu
/// bar, a notch, or an OS that parks it off-screen — so this also detects that
/// and falls back to the Dock; otherwise the app would be running but
/// unreachable.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let updater: Updater
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var placementAttempts = 0
    private var placementTimer: Timer?
    private(set) var isHiddenFromMenuBar = false

    init(model: AppModel, updater: Updater) {
        self.model = model
        self.updater = updater
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = Self.icon(attached: false, revealed: false)
        statusItem.button?.toolTip = "SlopDrop"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        Publishers.CombineLatest(model.$attachment, model.$revealed)
            .sink { [weak self] attachment, revealed in
                self?.statusItem.button?.image = Self.icon(attached: attachment.isAttached, revealed: revealed)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(model.$showInDock, model.$menuBarFull)
            .sink { showInDock, menuBarFull in
                NSApp.setActivationPolicy(showInDock || menuBarFull ? .regular : .accessory)
            }
            .store(in: &cancellables)
    }

    deinit {
        placementTimer?.invalidate()
    }

    /// Muting: the sparkle sunk into frosted glass. Paused (Mute Slop off):
    /// the sparkle in front of the glass. Not attached: a hollow sparkle.
    /// Drawn by Assets/Source/icons.py.
    private static func icon(attached: Bool, revealed: Bool) -> NSImage? {
        let name = !attached ? "MenuBarDisconnected" : (revealed ? "MenuBarPaused" : "MenuBarMuting")
        guard let image = AppResources.bundle.image(forResource: name) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "SlopDrop"
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .regular).applying(.init(paletteColors: [NSColor(model.attachment.color)])))
        menu.addItem(status)
        if !model.attachment.isAttached && !model.attachment.isBusy {
            menu.addItem(item("Connect to Slack", #selector(connect)))
        }
        if let release = updater.available {
            let installing = updater.activity == .installing
            let update = item(installing ? "Installing SlopDrop \(release.versionText)…" : "Update to SlopDrop \(release.versionText)", #selector(installUpdate))
            update.isEnabled = !installing
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(update)
        }
        menu.addItem(.separator())

        let mute = item("Mute Slop", #selector(toggleMute))
        mute.state = model.muted ? .on : .off
        menu.addItem(mute)
        let pick = item(model.pickMode ? "Cancel Picking" : "Pick a Message to Mute…", #selector(togglePick))
        pick.isEnabled = model.attachment.isAttached
        menu.addItem(pick)
        menu.addItem(item("Apps…", #selector(openApps)))
        menu.addItem(.separator())
        if updater.available == nil, updater.current != nil {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit SlopDrop", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func connect() { model.connect() }
    @objc private func toggleMute() { model.revealed.toggle() }
    @objc private func openApps() { SettingsWindowController.shared.show(page: .apps) }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func installUpdate() { updater.install() }

    @objc private func checkForUpdates() {
        SettingsWindowController.shared.show(page: .about)
        updater.check(userInitiated: true)
    }

    @objc private func togglePick() {
        if model.pickMode {
            model.cancelPicking()
        } else {
            model.beginPicking()
            SlackLauncher.runningApplications.first?.activate()
        }
    }

    // MARK: - Placement

    /// The system lays status items out after launch, and an item that doesn't
    /// fit ends up either unplaced (zero-height window) or parked at a negative
    /// x. Poll briefly, then fall back to the Dock.
    func startWatchingPlacement() {
        placementTimer?.invalidate()
        placementAttempts = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.placementAttempts += 1
                if self.isStatusItemVisible {
                    timer.invalidate()
                    self.placementTimer = nil
                    return
                }
                guard self.placementAttempts >= 6 else { return }  // ~3s
                timer.invalidate()
                self.placementTimer = nil
                self.fallBackToDock()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        placementTimer = timer
    }

    var isStatusItemVisible: Bool {
        guard let frame = statusItem.button?.window?.frame,
              frame.width > 0, frame.height > 0,
              let screen = NSScreen.screens.first
        else { return false }
        return frame.minX >= screen.frame.minX && frame.intersects(screen.frame)
    }

    private func fallBackToDock() {
        guard !isHiddenFromMenuBar else { return }
        isHiddenFromMenuBar = true
        model.menuBarFull = true
        NSLog("SlopDrop: menu bar did not place the status item; using the Dock")

        if !UserDefaults.standard.bool(forKey: Keys.fallbackAnnounced) {
            UserDefaults.standard.set(true, forKey: Keys.fallbackAnnounced)
            SettingsWindowController.shared.show()
        }
    }

    private enum Keys {
        static let fallbackAnnounced = "dockFallbackAnnounced"
    }
}
