import CryptoKit
import Foundation

/// Downloads a release, proves it's intact and really is SlopDrop, then swaps
/// it in for the app at `target`. Nothing is touched until every check passes.
enum UpdateInstaller {
    static func install(_ release: Release, replacing target: URL, using session: URLSession) async throws {
        // A quarantined app launched from Downloads runs from a read-only copy.
        if target.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        let folder = target.deletingLastPathComponent()
        let files = FileManager.default
        guard files.isWritableFile(atPath: folder.path), files.isWritableFile(atPath: target.path) else {
            throw UpdateError.notWritable(folder.path)
        }

        // On the target's volume, so the final swap is a rename rather than a copy.
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: staging) }

        let sums = try await fetch(release.checksums, using: session)
        let (downloaded, response) = try await session.download(from: release.archive)
        let archive = staging.appending(path: release.archiveName)
        try files.moveItem(at: downloaded, to: archive)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw UpdateError.unreachable
        }
        guard let expected = digest(named: release.archiveName, in: sums), try digest(of: archive) == expected else {
            throw UpdateError.checksumMismatch
        }

        let unpacked = staging.appending(path: "unpacked")
        try await run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let app = unpacked.appending(path: "SlopDrop.app")
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == release.versionText else {
            throw UpdateError.unexpectedBundle
        }
        // URLSession doesn't quarantine what it downloads, so this is normally a
        // no-op; a quarantined copy would relaunch into Gatekeeper's warning.
        try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

        _ = try files.replaceItemAt(target, withItemAt: app)
    }

    private static func fetch(_ url: URL, using session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.unreachable
        }
        return data
    }

    private static func digest(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads `shasum -a 256` output: `<hex>  <name>`, or `<hex> *<name>` in
    /// binary mode.
    private static func digest(named name: String, in sums: Data) -> String? {
        for line in String(decoding: sums, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            let file = fields[1].trimmingCharacters(in: .whitespaces)
            if file == name || file == "*" + name { return fields[0].lowercased() }
        }
        return nil
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.toolFailed(URL(fileURLWithPath: tool).lastPathComponent))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
