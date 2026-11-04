import AppKit
import CryptoKit

/// Slack avatars, fetched through Slack's own renderer and cached on disk so
/// they still show while Slack is disconnected. SlopDrop makes no network
/// requests of its own.
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()

    @Published private var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var failed: [String: Date] = [:]
    var loader: ((String) async -> Data?)?

    private static var directory: URL { RuleStore.directory.appendingPathComponent("icons", isDirectory: true) }

    func image(for url: String) -> NSImage? {
        if let image = images[url] { return image }
        load(url)
        return nil
    }

    private func load(_ url: String) {
        guard !inFlight.contains(url) else { return }
        if let at = failed[url], Date().timeIntervalSince(at) < 30 { return }

        let file = Self.directory.appendingPathComponent(Self.key(url))
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            // Publishing during a view update is not allowed; defer a turn.
            DispatchQueue.main.async { self.images[url] = image }
            return
        }
        guard let loader else { return }

        inFlight.insert(url)
        Task {
            let data = await loader(url)
            inFlight.remove(url)
            guard let data, let image = NSImage(data: data) else {
                failed[url] = Date()
                return
            }
            images[url] = image
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func key(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
