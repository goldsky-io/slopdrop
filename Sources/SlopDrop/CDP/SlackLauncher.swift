import AppKit

/// Starts Slack with the DevTools port open. Slack only reads that flag at
/// launch, so an already-running Slack has to be restarted once.
enum SlackLauncher {
    static let bundleIdentifier = "com.tinyspeck.slackmacgap"

    static var runningApplications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    }

    static var isRunning: Bool { !runningApplications.isEmpty }

    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Quits Slack if needed, then launches it with the debugging port and waits
    /// for the port to answer. Returns the number of attempts' worth of truth.
    static func relaunch(port: Int) async throws {
        if isRunning {
            for app in runningApplications { app.terminate() }
            let deadline = Date().addingTimeInterval(8)
            while isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if isRunning {
                for app in runningApplications { app.forceTerminate() }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }

        try launch(port: port)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await SlackBridge.isPortOpen(port) { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw CDPError(message: "Slack started but never opened the debugging port")
    }

    private static func launch(port: Int) throws {
        guard let appURL = applicationURL else {
            throw CDPError(message: "Slack.app is not installed")
        }

        // Preferred: LaunchServices, so the app gets its normal environment.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--remote-debugging-port=\(port)"]
        configuration.createsNewApplicationInstance = false

        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            launchError = error
            semaphore.signal()
        }
        semaphore.wait()

        if launchError == nil { return }

        // Fallback: exec the binary directly. Same result, no LaunchServices.
        let binary = appURL.appendingPathComponent("Contents/MacOS/Slack")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--remote-debugging-port=\(port)"]
        try process.run()
    }
}
