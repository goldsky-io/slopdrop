import Foundation

/// An installed Slack app that can post, read from Slack's own app store state.
struct CatalogApp: Decodable, Hashable {
    let id: String
    let name: String
    let desc: String
    let developer: String
    let icon: String
    let botUserId: String
    /// Slack's `is_ai_app`.
    let ai: Bool
    /// Slack's `is_agent_app`.
    let agent: Bool

    private enum CodingKeys: String, CodingKey { case id, name, desc, developer, icon, botUserId, ai, agent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        id = string(.id)
        name = string(.name)
        desc = string(.desc)
        developer = string(.developer)
        icon = string(.icon)
        botUserId = string(.botUserId)
        ai = (try? c.decode(Bool.self, forKey: .ai)) ?? false
        agent = (try? c.decode(Bool.self, forKey: .agent)) ?? false
    }
}

/// What the agent saw in rendered messages since it was last asked.
struct Observation: Decodable {
    let key: String
    let appId: String
    let botId: String
    let name: String
    let icon: String
    let via: String
    let ids: [String]
    let onBehalf: Int

    private enum CodingKeys: String, CodingKey { case key, appId, botId, name, icon, via, ids, onBehalf }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        key = string(.key)
        appId = string(.appId)
        botId = string(.botId)
        name = string(.name)
        icon = string(.icon)
        via = string(.via)
        ids = (try? c.decode([String].self, forKey: .ids)) ?? []
        onBehalf = (try? c.decode(Int.self, forKey: .onBehalf)) ?? 0
    }
}

struct SeenTally: Codable, Hashable {
    var key: String
    var name: String
    var appId: String
    var botId: String
    var icon: String
    var via: String
    var count: Int
    var onBehalf: Int
    var lastSeen: Date
}

/// Running counts of who posts what, kept across launches so suggestions get
/// better as you read Slack. Message ids are remembered (bounded) so scrolling
/// back through a channel doesn't count the same post twice.
struct SeenStore: Codable {
    private(set) var tallies: [String: SeenTally] = [:]
    private var counted: [String] = []
    private var countedSet: Set<String> = []

    private static let maxCounted = 8000

    private enum CodingKeys: String, CodingKey { case tallies, counted }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tallies = (try? c.decode([String: SeenTally].self, forKey: .tallies)) ?? [:]
        counted = (try? c.decode([String].self, forKey: .counted)) ?? []
        countedSet = Set(counted)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tallies, forKey: .tallies)
        try c.encode(counted, forKey: .counted)
    }

    static var fileURL: URL { RuleStore.directory.appendingPathComponent("seen.json") }

    static func load() -> SeenStore {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(SeenStore.self, from: data)
        else { return SeenStore() }
        return store
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: RuleStore.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("SlopDrop: could not save seen tallies — \(error)")
        }
    }

    /// Returns true when anything new was counted.
    mutating func ingest(_ observations: [Observation], at now: Date = Date()) -> Bool {
        var changed = false
        for observation in observations where !observation.key.isEmpty {
            let fresh = observation.ids.filter { !countedSet.contains($0) }
            var tally = tallies[observation.key] ?? SeenTally(
                key: observation.key, name: observation.name, appId: observation.appId,
                botId: observation.botId, icon: observation.icon, via: observation.via,
                count: 0, onBehalf: 0, lastSeen: now
            )
            if tally.icon.isEmpty, !observation.icon.isEmpty { tally.icon = observation.icon; changed = true }
            if tally.name.isEmpty, !observation.name.isEmpty { tally.name = observation.name; changed = true }
            if !fresh.isEmpty {
                let share = observation.ids.isEmpty ? 0 : fresh.count * observation.onBehalf / observation.ids.count
                tally.count += fresh.count
                tally.onBehalf += share
                tally.lastSeen = now
                remember(fresh)
                changed = true
            }
            tallies[observation.key] = tally
        }
        return changed
    }

    private mutating func remember(_ ids: [String]) {
        counted.append(contentsOf: ids)
        countedSet.formUnion(ids)
        if counted.count > Self.maxCounted {
            let overflow = counted.count - Self.maxCounted
            for id in counted.prefix(overflow) { countedSet.remove(id) }
            counted.removeFirst(overflow)
        }
    }
}

/// A candidate for hiding, with the reasons it was suggested.
struct Suggestion: Identifiable, Hashable {
    enum Kind: Hashable { case app, bot, signature }

    enum Signal: Hashable {
        case slackAI
        case slackAgent
        case aiName
        case sentUsing(Int)
        case seen(Int)

        var label: String {
            switch self {
            case .slackAI: return "Slack AI app"
            case .slackAgent: return "Slack agent"
            case .aiName: return "AI in name"
            case .sentUsing(let n): return n == 1 ? "1 “Sent using” post" : "\(n) “Sent using” posts"
            case .seen(let n): return n == 1 ? "1 post seen" : "\(n) posts seen"
            }
        }
    }

    let id: String
    let kind: Kind
    let name: String
    let detail: String
    let icon: String
    let signals: [Signal]
    let score: Int
    let seen: Int
    let onBehalf: Int
    let match: Match

    /// Enough independent evidence that this is an AI tool.
    var likelyAI: Bool { score >= 3 }

    var kindLabel: String {
        switch kind {
        case .signature: return "Signature"
        case .bot: return "Bot"
        case .app:
            if signals.contains(.slackAI) { return "AI app" }
            if signals.contains(.slackAgent) { return "Agent" }
            return "App"
        }
    }

    var subtitle: String {
        var parts = signals.map(\.label)
        if parts.isEmpty, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    func makeRule(style: String?) -> Rule {
        var rule = Rule()
        rule.name = name
        rule.style = style
        rule.match = match
        rule.icon = icon.isEmpty ? nil : icon
        return rule
    }
}

enum SuggestionEngine {
    /// Names and descriptions that strongly suggest an AI tool.
    private static let aiWords = try! NSRegularExpression(
        pattern: #"(?i)(\b(ai|a\.i\.|gpt|llms?|genai|chatbot|copilot|assistant|agentic)\b|\(ai\)|claude|anthropic|openai|chatgpt|gemini|cursor|devin|steery|perplexity|grok|mistral|llama|glean|lindy|granola|fireflies|otter\.ai|notion ai)"#
    )
    /// Weaker hints, only meaningful alongside Slack's agent flag.
    private static let botWords = try! NSRegularExpression(pattern: #"(?i)(bot\b|\bbot|brain\b)"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func build(catalog: [CatalogApp], seen: [String: SeenTally]) -> [Suggestion] {
        var tallies = seen
        var out: [Suggestion] = []

        for app in catalog where !app.id.isEmpty {
            let key = "app:\(app.id)"
            let tally = tallies.removeValue(forKey: key)
            out.append(make(
                key: key, kind: .app, name: app.name, detail: app.desc.isEmpty ? app.developer : app.desc,
                icon: app.icon.isEmpty ? tally?.icon ?? "" : app.icon,
                ai: app.ai, agent: app.agent,
                text: [app.name, app.desc, app.developer].joined(separator: " "),
                tally: tally, match: { var m = Match(); m.appIds = [app.id]; return m }()
            ))
        }

        for tally in tallies.values {
            let kind: Suggestion.Kind
            var match = Match()
            if tally.key.hasPrefix("app:") {
                kind = .app
                match.appIds = [tally.appId]
            } else if tally.key.hasPrefix("bot:") {
                kind = .bot
                match.botIds = [tally.botId]
            } else {
                kind = .signature
                match.via = [tally.via.lowercased()]
            }
            let name = kind == .signature ? tally.via : tally.name
            guard !name.isEmpty else { continue }
            out.append(make(
                key: tally.key, kind: kind, name: name, detail: "", icon: tally.icon,
                ai: false, agent: false, text: name, tally: tally, match: match
            ))
        }

        return out.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.onBehalf != $1.onBehalf { return $0.onBehalf > $1.onBehalf }
            if $0.seen != $1.seen { return $0.seen > $1.seen }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func make(
        key: String, kind: Suggestion.Kind, name: String, detail: String, icon: String,
        ai: Bool, agent: Bool, text: String, tally: SeenTally?, match: Match
    ) -> Suggestion {
        var signals: [Suggestion.Signal] = []
        var score = 0
        if ai { signals.append(.slackAI); score += 3 }
        if agent && !ai { signals.append(.slackAgent); score += 2 }
        if matches(aiWords, text) { signals.append(.aiName); score += 2 }
        else if agent && matches(botWords, text) { score += 1 }
        let onBehalf = max(tally?.onBehalf ?? 0, kind == .signature ? tally?.count ?? 0 : 0)
        if onBehalf > 0 { signals.append(.sentUsing(onBehalf)); score += 3 }
        let count = tally?.count ?? 0
        if count > 0 && onBehalf != count { signals.append(.seen(count)) }

        return Suggestion(
            id: key, kind: kind, name: name, detail: detail, icon: icon, signals: signals,
            score: score, seen: count, onBehalf: onBehalf, match: match
        )
    }
}
