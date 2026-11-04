import AppKit
import SwiftUI

@MainActor
final class SettingsRouter: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case general, apps, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .apps: return "Apps"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .apps: return "square.stack.3d.up.fill"
            case .about: return "info"
            }
        }

        var colors: [Color] {
            switch self {
            case .general: return [Color(white: 0.6), Color(white: 0.42)]
            case .apps: return [Color(red: 0.6, green: 0.45, blue: 0.98), Color(red: 0.44, green: 0.3, blue: 0.88)]
            case .about: return [Color(red: 0.36, green: 0.62, blue: 1), Color(red: 0.2, green: 0.43, blue: 0.93)]
            }
        }
    }

    @Published var page: Page = .general
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var router: SettingsRouter
    @ObservedObject var updater: Updater
    @State private var query = ""

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, router: router, updater: updater, query: $query)
                .frame(width: 236)
                .background(Palette.sidebar)
            Rectangle().fill(Palette.hairline).frame(width: 0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(WindowBackground())
        .foregroundStyle(Palette.ink)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 760, minHeight: 520)
        // Searching is searching the apps.
        .onChange(of: query) { _, text in
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { router.page = .apps }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                Group {
                    switch router.page {
                    case .general: GeneralPane(model: model)
                    case .apps: AppsPane(model: model, query: trimmedQuery)
                    case .about: AboutPane(updater: updater)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(router.page.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if router.page == .apps {
                PickButton(model: model)
            }
        }
        .padding(.horizontal, 32)
        .frame(height: 52)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var router: SettingsRouter
    @ObservedObject var updater: Updater
    @Binding var query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 48)
            SearchField(text: $query)
            identity.padding(.top, 14)

            VStack(spacing: 2) {
                ForEach(SettingsRouter.Page.allCases) { page in
                    NavRow(
                        title: page.title,
                        symbol: page.symbol,
                        colors: page.colors,
                        selected: router.page == page,
                        // Like Software Update in System Settings.
                        badge: page == .about && updater.available != nil
                    ) {
                        if page != .apps { query = "" }
                        router.page = page
                    }
                }
            }
            .padding(.top, 14)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var identity: some View {
        HStack(spacing: 10) {
            // The icon's body is 824/1024 of its canvas: 40pt draws a 32pt squircle.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .padding(-4)
            VStack(alignment: .leading, spacing: 2) {
                Text("SlopDrop").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    StatusDot(color: model.attachment.color)
                    Text(model.shortStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.inkTertiary)
            TextField("Search apps…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.field))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? Palette.accent.opacity(0.5) : Palette.cardEdge, lineWidth: focused ? 1 : 0.5)
        )
    }
}

private struct NavRow: View {
    let title: String
    let symbol: String
    let colors: [Color]
    let selected: Bool
    var badge = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(symbol: symbol, colors: colors)
                Text(title).font(.system(size: 13))
                Spacer()
                if badge {
                    Text("1")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(Palette.negative))
                        .accessibilityLabel("Update available")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.selection : (hovering ? Palette.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct EmptyCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        CardSection {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Palette.inkTertiary)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
        }
    }
}
