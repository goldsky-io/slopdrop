import Foundation

/// One row on the Apps page: an app, bot, "Sent using" tool or hand-written
/// rule, plus the rule that sets it, if the user has touched it.
struct AppEntry: Identifiable, Hashable {
    enum Kind: Hashable { case app, bot, signature, person, custom }

    let id: String
    let kind: Kind
    let name: String
    let detail: String
    let icon: String?
    /// The user's own setting. Without one, the row follows "All apps and bots".
    let rule: Rule?
    let suggestion: Suggestion?

    init(rule: Rule?, suggestion: Suggestion?) {
        self.rule = rule
        self.suggestion = suggestion
        id = suggestion?.id ?? rule?.entryID ?? UUID().uuidString

        if let suggestion {
            switch suggestion.kind {
            case .app: kind = .app
            case .bot: kind = .bot
            case .signature: kind = .signature
            }
        } else if let match = rule?.match {
            if !match.appIds.isEmpty { kind = .app }
            else if !match.botIds.isEmpty { kind = .bot }
            else if !match.via.isEmpty { kind = .signature }
            else if !match.userIds.isEmpty { kind = .person }
            else { kind = .custom }
        } else {
            kind = .custom
        }

        name = suggestion?.name ?? rule?.name ?? "Untitled"
        let subtitle = suggestion?.subtitle ?? ""
        detail = subtitle.isEmpty ? rule?.summary ?? "" : subtitle
        let icon = rule?.icon ?? suggestion?.icon
        self.icon = icon?.isEmpty == false ? icon : nil
    }

    /// "All apps and bots" reaches apps, bots and tools, never a person.
    var followsAllApps: Bool { rule?.reachedByAllApps ?? (kind == .app || kind == .bot || kind == .signature) }

    /// A hand-written or picked rule with no app behind it; removing it is the
    /// only way back.
    var isCustom: Bool { suggestion == nil && (kind == .person || kind == .custom) }

    var fallbackSymbol: String? {
        switch kind {
        case .signature: return "signature"
        case .person: return "person.fill"
        case .custom: return "text.magnifyingglass"
        case .app, .bot: return nil
        }
    }

    /// The rule to write when the user first changes this row.
    func makeRule() -> Rule {
        rule ?? suggestion?.makeRule(style: nil) ?? Rule()
    }
}
