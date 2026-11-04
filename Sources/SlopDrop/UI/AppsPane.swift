import SwiftUI
import UniformTypeIdentifiers

/// Every app, bot and tool SlopDrop knows about, with a switch to mute it —
/// a single list like the ones in System Settings, dragged into priority order.
struct AppsPane: View {
    @ObservedObject var model: AppModel
    /// Search text from the sidebar; filters the list and disables reordering.
    let query: String
    @State private var showQuiet = false
    @State private var dragging: String?

    var body: some View {
        let entries = model.appEntries.filter(matches)
        let quiet = model.quietApps.filter(matches)

        VStack(alignment: .leading, spacing: 24) {
            if model.pickMode {
                PickBanner(model: model)
            }

            if query.isEmpty {
                CardSection(footer: "Switch an app off below to let it through.") {
                    AllAppsRow(model: model)
                }
            }

            if entries.isEmpty && (quiet.isEmpty || query.isEmpty) {
                if query.isEmpty {
                    EmptyCard(
                        symbol: "square.stack.3d.up",
                        title: "No apps yet",
                        message: "Apps show up here as SlopDrop finds them in Slack. You can also pick a message in Slack to mute whoever posted it."
                    )
                } else {
                    EmptyCard(symbol: "magnifyingglass", title: "No matches", message: "No app or tool named “\(query)”.")
                }
            }

            if !entries.isEmpty {
                CardSection(
                    title: "Apps",
                    footer: query.isEmpty ? "Drag to reorder. If two rows cover the same message, the higher one wins." : nil
                ) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { CardDivider(inset: 54) }
                        AppRow(model: model, entry: entry, reorderable: query.isEmpty)
                            .onDrag {
                                dragging = entry.id
                                return NSItemProvider(object: entry.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDrop(target: entry.id, model: model, dragging: $dragging))
                    }
                }
            }

            if !quiet.isEmpty {
                if showQuiet || !query.isEmpty {
                    CardSection(title: "Other installed apps", footer: "No sign of AI and no posts seen yet.") {
                        ForEach(Array(quiet.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { CardDivider(inset: 54) }
                            AppRow(model: model, entry: entry, reorderable: false)
                        }
                    }
                }
                if query.isEmpty {
                    Button(showQuiet ? "Hide other installed apps" : "Show \(quiet.count) other installed apps") {
                        withAnimation(.easeOut(duration: 0.2)) { showQuiet.toggle() }
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
        }
    }

    private func matches(_ entry: AppEntry) -> Bool {
        query.isEmpty
            || entry.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || entry.detail.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Moves the dragged row into place as it passes over another, so the list
/// reorders live under the pointer.
private struct ReorderDrop: DropDelegate {
    let target: String
    let model: AppModel
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.move(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct AllAppsRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let muted = model.allAppsMuted
        HStack(spacing: 12) {
            RemoteIcon(url: nil, fallback: "square.stack.3d.up.fill", monogram: "Apps", size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("All apps and bots")
                    .font(.system(size: 13, weight: .medium))
                Text(muted ? "Every app and bot is muted, new ones too" : "Only the apps switched on below are muted")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if muted {
                StyleMenu(model: model, selection: model.allAppsRule?.style, fallback: model.defaultStyle) {
                    model.setAllAppsStyle($0)
                }
            }
            Toggle("", isOn: Binding(get: { muted }, set: { model.setAllAppsMuted($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Mute all apps and bots")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct AppRow: View {
    @ObservedObject var model: AppModel
    let entry: AppEntry
    let reorderable: Bool
    @State private var hovering = false

    var body: some View {
        let muted = model.isMuted(entry)
        HStack(spacing: 12) {
            RemoteIcon(url: entry.icon, fallback: entry.fallbackSymbol, monogram: entry.name, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if entry.suggestion?.likelyAI == true {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.accent)
                            .help("Likely AI")
                    }
                }
                Text(entry.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            // Only a row's own style is worth showing at rest; one that
            // follows the default offers its menu on hover.
            if muted && (hovering || entry.rule?.style != nil) {
                StyleMenu(model: model, selection: entry.rule?.style, fallback: model.inheritedStyle(of: entry)) {
                    model.setStyle($0, entry)
                }
            }
            Toggle("", isOn: Binding(get: { muted }, set: { model.setMuted($0, entry) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Mute \(entry.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Palette.hover : .clear)
                .padding(3)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(muted ? "Let Through" : "Mute") { model.setMuted(!muted, entry) }
            if reorderable {
                Divider()
                Button("Move Up") { withAnimation { model.move(entry.id, by: -1) } }
                Button("Move Down") { withAnimation { model.move(entry.id, by: 1) } }
            }
            if entry.rule != nil {
                Divider()
                if entry.isCustom {
                    Button("Remove", role: .destructive) { model.reset(entry) }
                } else {
                    Button(entry.followsAllApps ? "Follow All Apps" : "Reset") { model.reset(entry) }
                }
            }
        }
    }
}

/// A compact style picker. `nil` follows `fallback`, and the label is dimmed
/// then so a row's own choice stands out.
struct StyleMenu: View {
    @ObservedObject var model: AppModel
    let selection: String?
    let fallback: String
    let onSelect: (String?) -> Void

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                let title = "Default (\(model.styleTitle(fallback)))"
                if selection == nil { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
            Divider()
            ForEach(model.availableStyles) { style in
                Button {
                    onSelect(style.id)
                } label: {
                    if style.id == selection {
                        Label(style.title, systemImage: "checkmark")
                    } else {
                        Text(style.title)
                    }
                }
            }
        } label: {
            Text(model.styleTitle(selection ?? fallback))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selection == nil ? Palette.inkSecondary : Palette.ink)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.pill))
        .help(selection == nil ? "Following the default style" : "Uses its own style")
    }
}

struct PickButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button {
            if model.pickMode { model.cancelPicking() } else { model.beginPicking() }
        } label: {
            Label(model.pickMode ? "Cancel" : "Pick from Slack", systemImage: model.pickMode ? "xmark" : "cursorarrow.rays")
        }
        .buttonStyle(SoftButtonStyle(prominent: !model.pickMode))
        .disabled(!model.attachment.isAttached)
        .help(model.attachment.isAttached ? "Click a message in Slack to mute whoever posted it" : "Connect to Slack first")
    }
}

private struct PickBanner: View {
    @ObservedObject var model: AppModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Palette.accent)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1 : 0.7)
                .opacity(pulse ? 1 : 0.5)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            VStack(alignment: .leading, spacing: 1) {
                Text("Click any message in Slack").font(.system(size: 13, weight: .medium))
                Text("SlopDrop will mute the app or tool that posted it and put it at the top of this list.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Button("Cancel") { model.cancelPicking() }
                .buttonStyle(SoftButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.accentFill))
        .onAppear { pulse = true }
    }
}
