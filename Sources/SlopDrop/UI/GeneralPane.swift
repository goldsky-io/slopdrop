import SwiftUI

struct GeneralPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            CardSection {
                ToggleRow(
                    title: "Mute slop",
                    subtitle: muteSubtitle,
                    isOn: Binding(get: { model.muted }, set: { model.revealed = !$0 })
                )
                CardDivider()
                ToggleRow(
                    title: "Reconnect automatically",
                    subtitle: "Restart Slack with its control port when it comes back without one.",
                    isOn: $model.autoReconnect
                )
                CardDivider()
                ToggleRow(
                    title: "Show in Dock",
                    subtitle: model.menuBarFull
                        ? "Your menu bar is full, so SlopDrop lives in the Dock."
                        : "Keep an icon in the Dock as well as the menu bar.",
                    isOn: Binding(get: { model.showInDock || model.menuBarFull }, set: { model.showInDock = $0 }),
                    disabled: model.menuBarFull
                )
            }

            CardSection(title: "Connection") {
                CardRow(title: "Slack", subtitle: model.statusText) {
                    StatusDot(color: model.attachment.color)
                } trailing: {
                    Button(model.attachment.isAttached ? "Reconnect" : "Connect") { model.connect() }
                        .buttonStyle(SoftButtonStyle(prominent: !model.attachment.isAttached))
                        .disabled(model.attachment.isBusy)
                }
                CardDivider()
                CardRow(title: "Control port", subtitle: "Loopback only. Slack opens it when SlopDrop starts it.") {
                    Text(verbatim: "127.0.0.1:\(model.port)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Palette.inkSecondary)
                }
            }

            CardSection(title: "Style", footer: styleFooter) {
                StyleGallery(styles: model.availableStyles, selection: $model.defaultStyle)
            }
        }
    }

    private var styleFooter: String {
        let base = "Applies right away to every app that doesn't have its own style."
        if let all = model.allAppsRule, all.enabled, let style = all.style {
            return base + " All apps and bots uses \(model.styleTitle(style)); change it on the Apps page."
        }
        let own = model.rules.filter { $0.style != nil && !$0.match.anyApp }.count
        switch own {
        case 0: return base
        case 1: return base + " 1 app has its own style; change it on the Apps page."
        default: return base + " \(own) apps have their own style; change them on the Apps page."
        }
    }

    private var muteSubtitle: String {
        if model.revealed { return "Paused. Everything in Slack is visible; your settings are kept." }
        guard model.attachment.isAttached else { return "Applies as soon as SlopDrop is attached to Slack." }
        let matched = model.stats.matched
        let total = model.stats.messages
        if total == 0 { return "Nothing on screen in Slack right now." }
        return matched == 1 ? "Muting 1 of \(total) messages on screen." : "Muting \(matched) of \(total) messages on screen."
    }
}
