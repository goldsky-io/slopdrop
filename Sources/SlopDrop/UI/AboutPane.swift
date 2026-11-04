import SwiftUI

/// Who and what this build is, whether there's a newer one, and where the
/// project lives — laid out like Raycast's About page.
struct AboutPane: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            masthead

            CardSection(title: "Updates") {
                // Re-render once a minute so "checked 3 minutes ago" stays true.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    CardRow(title: "SlopDrop Updates", subtitle: status(at: context.date)) {
                        updateAction
                    }
                }
                CardDivider()
                ToggleRow(
                    title: "Check automatically",
                    subtitle: "On launch and once a day. One request to github.com; nothing about you or Slack is sent.",
                    isOn: $updater.checksAutomatically,
                    disabled: updater.current == nil
                )
                CardDivider()
                LinkRow(title: "Release Notes", symbol: "doc.text", url: updater.available?.page ?? Release.repository.appending(path: "releases"))
            }

            CardSection(title: "Links") {
                LinkRow(title: "Source Code", symbol: "chevron.left.forwardslash.chevron.right", url: Release.repository)
                CardDivider()
                LinkRow(title: "Report an Issue", symbol: "exclamationmark.bubble", url: Release.repository.appending(path: "issues/new"))
            }
        }
    }

    private var masthead: some View {
        VStack(spacing: 4) {
            // The icon's body is 824/1024 of its canvas, so 96pt draws a ~77pt squircle.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
            Text("SlopDrop")
                .font(.system(size: 22, weight: .bold))
            Text(versionLine)
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkSecondary)
            if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                Text(copyright)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var versionLine: String {
        guard let current = updater.current else { return "Development build" }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "Version \(current) (\($0))" } ?? "Version \(current)"
    }

    @ViewBuilder
    private var updateAction: some View {
        switch updater.activity {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .idle, .failed:
            if updater.available != nil {
                Button("Install and Relaunch") { updater.install() }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            } else {
                Button("Check Now") { updater.check(userInitiated: true) }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(updater.current == nil)
            }
        }
    }

    private func status(at now: Date) -> String {
        switch updater.activity {
        case .checking:
            return "Checking for updates…"
        case .installing:
            return "Installing \(updater.available?.versionText ?? "the update")… SlopDrop relaunches when it's done."
        case .failed(let message):
            return message
        case .idle:
            break
        }
        guard let current = updater.current else { return "Updates are off for development builds." }
        if let release = updater.available { return "Version \(release.versionText) is available. You have \(current)." }
        guard let checked = updater.lastChecked else { return "Not checked yet." }
        return "You're up to date. Checked \(Self.relative(checked, to: now))."
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static func relative(_ date: Date, to now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : formatter.localizedString(for: date, relativeTo: now)
    }
}
