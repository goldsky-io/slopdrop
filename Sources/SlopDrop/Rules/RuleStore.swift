import Foundation

/// Rules live next to the app's other state as plain JSON, so they are easy to
/// inspect, diff, and hand-edit.
struct RuleStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SlopDrop", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("rules.json") }

    /// What a first launch starts with: app and bot posts are muted by the
    /// catch-all, and the Apps page switches back on the few you want to read.
    static var defaults: [Rule] {
        var rule = Rule()
        rule.name = "All apps and bots"
        rule.match.anyApp = true
        return [rule]
    }

    static func load() -> [Rule] {
        guard let data = try? Data(contentsOf: fileURL),
              let rules = try? JSONDecoder().decode([Rule].self, from: data)
        else { return [] }
        return rules
    }

    /// Rules for launch. With no file at all this is a first launch, so it
    /// starts from `defaults`; once the file exists it is the whole truth, so
    /// switching the catch-all off stays off. A file that exists but doesn't
    /// decode is left alone rather than quietly replaced by muting everything.
    static func loadOrSeed() -> [Rule] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            save(defaults)
            return defaults
        }
        return load()
    }

    static func save(_ rules: [Rule]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rules).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("SlopDrop: could not save rules — \(error)")
        }
    }
}
