import Foundation

/// The SwiftPM resource bundle, found wherever this build actually put it.
///
/// `Bundle.module` can't be trusted here. Its generated accessor looks beside
/// the executable and at the directory this package was built in, and on some
/// toolchains it never checks `Contents/Resources` at all — so a packaged app
/// either crashes on launch or, worse, quietly reads resources out of the
/// developer's `.build` folder and only works on the machine that built it.
enum AppResources {
    static let bundle: Bundle = {
        let name = "SlopDrop_SlopDrop.bundle"
        let candidates = [
            // Inside the app bundle: dist/SlopDrop.app/Contents/Resources.
            Bundle.main.resourceURL?.appendingPathComponent(name),
            // Straight from `swift build`, next to the executable.
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        for url in candidates.compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        fatalError("SlopDrop: could not find \(name)")
    }()
}
