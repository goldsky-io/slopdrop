import Foundation

/// A version as SlopDrop's release tags spell it: `v1.2.3`, or `v1.2.3-rc.1`
/// for a prerelease, which sorts before the release it leads up to.
struct AppVersion: Comparable, CustomStringConvertible {
    let numbers: [Int]
    let prerelease: String?

    init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespaces))
        if text.first == "v" { text = text.dropFirst() }
        let parts = text.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        self.prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    /// This build's version; nil when it isn't running from an app bundle
    /// (`swift run`), which has nothing to update.
    static let current = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")

    var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        case (_?, nil): return true
        default: return false
        }
    }

    /// 0.2 and 0.2.0 are the same version, so equality follows the ordering.
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// A published release, found at the URLs the release workflow produces:
/// `SlopDrop-<version>.zip` and `SHA256SUMS` attached to the tag.
struct Release: Equatable {
    static let repository = URL(string: "https://github.com/goldsky-io/slopdrop")!

    let tag: String
    let version: AppVersion

    /// The tag without its `v`, exactly as the workflow names the archive.
    var versionText: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    var page: URL { Self.repository.appending(path: "releases/tag/\(tag)") }
    var archiveName: String { "SlopDrop-\(versionText).zip" }
    var archive: URL { Self.repository.appending(path: "releases/download/\(tag)/\(archiveName)") }
    var checksums: URL { Self.repository.appending(path: "releases/download/\(tag)/SHA256SUMS") }
}

enum ReleaseFeed {
    /// The newest published release. GitHub's `/releases/latest` skips drafts
    /// and prereleases and redirects to the release's own page, so the tag is
    /// read from that redirect. That's a single HEAD request, and it avoids the
    /// REST API, whose 60-an-hour anonymous limit is shared by everyone behind
    /// the same IP address.
    static func latest(using session: URLSession) async throws -> Release {
        var request = URLRequest(url: Release.repository.appending(path: "releases/latest"))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let url = http.url else {
            throw UpdateError.unreachable
        }
        let parts = url.pathComponents
        guard parts.count >= 2, parts[parts.count - 2] == "tag", let version = AppVersion(parts[parts.count - 1]) else {
            throw UpdateError.noRelease
        }
        return Release(tag: parts[parts.count - 1], version: version)
    }
}

enum UpdateError: LocalizedError {
    case unreachable
    case noRelease
    case checksumMismatch
    case unexpectedBundle
    case translocated
    case notWritable(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Couldn't reach GitHub. Check your connection and try again."
        case .noRelease:
            return "No release has been published yet."
        case .checksumMismatch:
            return "The download didn't match its checksum, so nothing was installed."
        case .unexpectedBundle:
            return "The download wasn't the SlopDrop build it should be, so nothing was installed."
        case .translocated:
            return "macOS is running SlopDrop from a temporary copy. Move it to Applications, then try again."
        case .notWritable(let folder):
            return "SlopDrop can't replace itself in \(folder). Install the update with the command in the README instead."
        case .toolFailed(let tool):
            return "\(tool) failed, so nothing was installed."
        }
    }

    /// What to tell someone about any failure along the way.
    static func message(for error: Error) -> String {
        if let error = error as? UpdateError, let text = error.errorDescription { return text }
        if error is URLError { return UpdateError.unreachable.errorDescription ?? "" }
        return error.localizedDescription
    }
}
