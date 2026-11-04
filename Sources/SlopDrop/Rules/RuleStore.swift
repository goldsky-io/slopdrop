import Foundation

/// Rules live next to the app's other state as plain JSON, so they are easy to
/// inspect, diff, and hand-edit.
struct RuleStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SlopDrop", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("rules.json") }

    static func load() -> [Rule] {
        guard let data = try? Data(contentsOf: fileURL),
              let rules = try? JSONDecoder().decode([Rule].self, from: data)
        else { return [] }
        return rules
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
