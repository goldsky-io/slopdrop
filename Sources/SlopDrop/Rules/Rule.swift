import Foundation

/// A filter rule. The `match` object is serialized verbatim and evaluated in
/// the renderer, so its property names are part of the wire format.
struct Rule: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String = "New rule"
    var enabled: Bool = true
    /// Style id from the renderer's registry (`accordion`, `blur`, ...), or nil
    /// to follow the default style chosen in Settings.
    var style: String?
    var match: Match = Match()
    /// Avatar shown next to the rule in Settings. Not used for matching.
    var icon: String?

    enum CodingKeys: String, CodingKey { case id, name, enabled, style, match, icon }

    /// Keys are optional on read so a hand-written rule can omit anything it
    /// doesn't care about.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled rule"
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        style = (try? c.decodeIfPresent(String.self, forKey: .style)) ?? nil
        match = (try? c.decode(Match.self, forKey: .match)) ?? Match()
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil
    }

    init() {}

    /// Plain-language description; ids stay out of the UI.
    var summary: String {
        var parts: [String] = []
        if match.anyApp { parts.append("Every app and bot") }
        if !match.appIds.isEmpty { parts.append(match.appIds.count == 1 ? "Posts by this app" : "Posts by \(match.appIds.count) apps") }
        if !match.botIds.isEmpty && match.appIds.isEmpty { parts.append("Posts by this bot") }
        if !match.via.isEmpty { parts.append("Sent using " + match.via.map(\.capitalized).joined(separator: ", ")) }
        if !match.userIds.isEmpty { parts.append(match.userIds.count == 1 ? "From one person" : "From \(match.userIds.count) people") }
        if !match.names.isEmpty { parts.append("Named " + match.names.joined(separator: ", ")) }
        if !match.channelIds.isEmpty { parts.append(match.channelIds.count == 1 ? "In one channel" : "In \(match.channelIds.count) channels") }
        if let text = match.text, !text.isEmpty { parts.append("Text matches /\(text)/") }
        if let metadata = match.metadata, !metadata.isEmpty { parts.append("Metadata contains \(metadata)") }
        return parts.isEmpty ? "Matches nothing yet" : parts.joined(separator: " · ")
    }

    /// The Apps-page row this rule belongs to. A rule for one app, bot or
    /// "Sent using" tool shares its id with that app's suggestion, so the two
    /// show as one row; anything else is a row of its own.
    var entryID: String {
        if match.anyApp { return "all" }
        if match.appIds.count == 1 { return "app:\(match.appIds[0])" }
        if match.botIds.count == 1 { return "bot:\(match.botIds[0])" }
        if match.via.count == 1 { return "via:\(match.via[0])" }
        return "rule:\(id)"
    }

    /// Whether the "All apps and bots" rule would reach what this rule matches.
    var reachedByAllApps: Bool {
        match.userIds.isEmpty && (!match.appIds.isEmpty || !match.botIds.isEmpty || !match.via.isEmpty)
    }
}

struct Match: Codable, Hashable {
    var anyApp: Bool = false
    var userIds: [String] = []
    var botIds: [String] = []
    var appIds: [String] = []
    var channelIds: [String] = []
    var names: [String] = []
    var subtypes: [String] = []
    /// Lowercased tool names from a "Sent using …" footer.
    var via: [String] = []
    /// Case-insensitive regular expression over the message text.
    var text: String?
    /// Substring match against the message's JSON metadata.
    var metadata: String?

    enum CodingKeys: String, CodingKey {
        case anyApp, userIds, botIds, appIds, channelIds, names, subtypes, via, text, metadata
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anyApp = (try? c.decode(Bool.self, forKey: .anyApp)) ?? false
        userIds = (try? c.decode([String].self, forKey: .userIds)) ?? []
        botIds = (try? c.decode([String].self, forKey: .botIds)) ?? []
        appIds = (try? c.decode([String].self, forKey: .appIds)) ?? []
        channelIds = (try? c.decode([String].self, forKey: .channelIds)) ?? []
        names = (try? c.decode([String].self, forKey: .names)) ?? []
        subtypes = (try? c.decode([String].self, forKey: .subtypes)) ?? []
        via = (try? c.decode([String].self, forKey: .via)) ?? []
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil
        metadata = (try? c.decodeIfPresent(String.self, forKey: .metadata)) ?? nil
    }
}

/// Style metadata as published by the renderer agent.
struct StyleDescriptor: Identifiable, Hashable, Decodable {
    let id: String
    let title: String
    let blurb: String

    static let defaultID = "monochrome"

    /// Mirrors the registry bundled in slop-agent.js so Settings can draw
    /// before Slack is attached. When attached, the agent's list wins. The
    /// default comes first.
    static let builtIn: [StyleDescriptor] = [
        .init(id: "monochrome", title: "Grayscale", blurb: "Drains colour so it reads as background noise, in a card. Long ones end in Show more. Faces of people who replied stay lit."),
        .init(id: "accordion", title: "Fold", blurb: "Keeps the sender and the first line. Click the message to unfold or fold it."),
        .init(id: "blur", title: "Frost", blurb: "Frosted glass over the message body. Hover to read."),
        .init(id: "dim", title: "Dim", blurb: "Fades the message, in a card, until you hover. Long ones end in Show more. Faces of people who replied stay lit."),
        .init(id: "outline", title: "Tag", blurb: "Labels the message and puts it in a card. Long ones end in Show more."),
        .init(id: "hide", title: "Hide", blurb: "Removes the message from the timeline."),
    ]
}

/// A message the user clicked while in pick mode.
struct PickedMessage: Decodable {
    let ts: String
    let channel: String
    let user: String
    let name: String
    let botId: String
    let appId: String
    let appName: String
    let icon: String
    let isApp: Bool
    let onBehalf: Bool
    let via: String

    private enum CodingKeys: String, CodingKey {
        case ts, channel, user, name, botId, appId, appName, icon, isApp, onBehalf, via
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        ts = string(.ts)
        channel = string(.channel)
        user = string(.user)
        name = string(.name)
        botId = string(.botId) == "unknown" ? "" : string(.botId)
        appId = string(.appId)
        appName = string(.appName)
        icon = string(.icon)
        isApp = (try? c.decode(Bool.self, forKey: .isApp)) ?? false
        onBehalf = (try? c.decode(Bool.self, forKey: .onBehalf)) ?? false
        via = string(.via)
    }

    /// Builds the most specific rule this message supports. A post made with
    /// someone's token mutes the tool, never the person.
    func makeRule(style: String?) -> Rule {
        var rule = Rule()
        rule.style = style
        rule.icon = icon.isEmpty ? nil : icon

        if !appId.isEmpty {
            rule.match.appIds = [appId]
            rule.name = onBehalf ? (via.isEmpty ? appName : via) : (appName.isEmpty ? name : appName)
        } else if onBehalf && !via.isEmpty {
            rule.match.via = [via.lowercased()]
            rule.name = via
            rule.icon = nil
        } else if !botId.isEmpty {
            rule.match.botIds = [botId]
            rule.name = name.isEmpty ? "Bot" : name
        } else if !user.isEmpty {
            rule.match.userIds = [user]
            rule.name = name.isEmpty ? "Muted person" : name
        } else if isApp {
            rule.match.anyApp = true
            rule.name = "Apps"
        }
        if rule.name.isEmpty { rule.name = "Muted" }
        return rule
    }
}

struct AgentStats {
    var messages = 0
    var matched = 0

    init() {}

    init(json: [String: Any]) {
        messages = json["messages"] as? Int ?? 0
        matched = json["matched"] as? Int ?? 0
    }
}
