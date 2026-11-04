import AppKit
import UserNotifications

/// Looks for a newer release, says so in Settings › About, the menu bar menu
/// and a notification, and installs it on request. Checking is one HEAD request
/// to github.com on launch and once a day; switching off "Check automatically"
/// stops even that.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    enum Activity: Equatable {
        case idle
        case checking
        case installing
        case failed(String)
    }

    /// The newest release, when it's newer than this build.
    @Published private(set) var available: Release?
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date

    @Published var checksAutomatically: Bool = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic)
            checkIfDue()
        }
    }

    let current = AppVersion.current

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    private var schedule: Task<Void, Never>?

    private let checkInterval: TimeInterval = 24 * 60 * 60
    /// How long a pending update waits before the notification comes back.
    private let reminderInterval: TimeInterval = 3 * 24 * 60 * 60

    private enum Keys {
        static let automatic = "checkForUpdates"
        static let lastChecked = "lastUpdateCheck"
        static let notifiedTag = "updateNotifiedTag"
        static let notifiedAt = "updateNotifiedAt"
    }

    private enum Notice {
        static let category = "update"
        static let install = "install"
        static let identifier = "update-available"
    }

    /// Call before launch finishes: a notification that launched the app is
    /// only delivered if the delegate is already in place.
    func start() {
        guard current != nil, schedule == nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let install = UNNotificationAction(identifier: Notice.install, title: "Install", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Notice.category, actions: [install], intentIdentifiers: [], options: []),
        ])

        schedule = Task { [weak self] in
            // Let Slack attach first; nothing about an update is urgent.
            try? await Task.sleep(for: .seconds(8))
            if self?.checksAutomatically == true { self?.check(userInitiated: false) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60))
                self?.checkIfDue()
                self?.notifyIfDue()
            }
        }
    }

    func check(userInitiated: Bool) {
        guard let current, activity != .checking, activity != .installing else { return }
        activity = .checking
        Task {
            do {
                let latest = try await ReleaseFeed.latest(using: session)
                let now = Date()
                lastChecked = now
                UserDefaults.standard.set(now, forKey: Keys.lastChecked)
                available = latest.version > current ? latest : nil
                if activity == .checking { activity = .idle }
                // Someone who pressed Check Now is already looking at the answer.
                if !userInitiated { notifyIfDue() }
            } catch {
                NSLog("SlopDrop: update check failed — \(error)")
                // A background check that fails stays quiet; the next one retries.
                if activity == .checking { activity = userInitiated ? .failed(UpdateError.message(for: error)) : .idle }
            }
        }
    }

    func install() {
        guard let release = available, activity != .installing else { return }
        activity = .installing
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Notice.identifier])
        Task {
            do {
                try await UpdateInstaller.install(release, replacing: Bundle.main.bundleURL, using: session)
                NSLog("SlopDrop: installed \(release.tag), relaunching")
                relaunch(into: release)
            } catch {
                NSLog("SlopDrop: update to \(release.tag) failed — \(error)")
                activity = .failed(UpdateError.message(for: error))
            }
        }
    }

    private func checkIfDue() {
        guard checksAutomatically else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < checkInterval { return }
        check(userInitiated: false)
    }

    /// Once when a version first shows up, then again every few days while it
    /// waits. The notification replaces the previous one rather than piling up.
    private func notifyIfDue() {
        guard let release = available, let current, activity != .installing else { return }
        let defaults = UserDefaults.standard
        let reminding = defaults.string(forKey: Keys.notifiedTag) == release.tag
        if reminding, let last = defaults.object(forKey: Keys.notifiedAt) as? Date,
           Date().timeIntervalSince(last) < reminderInterval { return }

        let center = UNUserNotificationCenter.current()
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = reminding
                ? "SlopDrop \(release.versionText) is still waiting"
                : "SlopDrop \(release.versionText) is available"
            content.body = "You're on \(current). Install updates and relaunches SlopDrop; Slack stays as it is."
            content.categoryIdentifier = Notice.category
            do {
                try await center.add(UNNotificationRequest(identifier: Notice.identifier, content: content, trigger: nil))
                defaults.set(release.tag, forKey: Keys.notifiedTag)
                defaults.set(Date(), forKey: Keys.notifiedAt)
            } catch {
                NSLog("SlopDrop: update notification failed — \(error)")
            }
        }
    }

    /// The new bundle already sits at our path; a shell waits for this process
    /// to exit, then opens it.
    private func relaunch(into release: Release) {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path,
        ]
        do {
            try waiter.run()
        } catch {
            activity = .failed("SlopDrop \(release.versionText) is installed. Quit and reopen SlopDrop to start it.")
            return
        }
        NSApp.terminate(nil)
    }
}

extension Updater: UNUserNotificationCenterDelegate {
    /// Settings may be frontmost, which would otherwise hide the banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case Notice.install: Updater.shared.install()
            case UNNotificationDefaultActionIdentifier: SettingsWindowController.shared.show(page: .about)
            default: break
            }
            completionHandler()
        }
    }
}
