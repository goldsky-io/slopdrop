import AppKit
import SwiftUI

/// Warm, tinted palette in the spirit of Raycast's light "Noon" / dark themes.
/// Every colour resolves per appearance, so views never branch on dark mode.
enum Palette {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
        })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    static let windowTop = dynamic(light: rgb(250, 236, 229, 0.86), dark: rgb(44, 35, 39, 0.82))
    static let windowBottom = dynamic(light: rgb(244, 224, 221, 0.9), dark: rgb(33, 27, 31, 0.88))
    static let sidebar = dynamic(light: rgb(255, 255, 255, 0.22), dark: rgb(255, 255, 255, 0.025))

    static let ink = dynamic(light: rgb(46, 30, 42), dark: rgb(244, 236, 240))
    static let inkSecondary = dynamic(light: rgb(122, 101, 113), dark: rgb(170, 155, 162))
    static let inkTertiary = dynamic(light: rgb(160, 141, 150), dark: rgb(124, 111, 118))

    static let card = dynamic(light: rgb(128, 66, 78, 0.045), dark: rgb(255, 255, 255, 0.045))
    static let cardEdge = dynamic(light: rgb(128, 66, 78, 0.07), dark: rgb(255, 255, 255, 0.07))
    static let hairline = dynamic(light: rgb(120, 62, 82, 0.1), dark: rgb(255, 255, 255, 0.07))
    static let field = dynamic(light: rgb(255, 255, 255, 0.6), dark: rgb(255, 255, 255, 0.06))
    static let hover = dynamic(light: rgb(128, 66, 78, 0.05), dark: rgb(255, 255, 255, 0.05))
    static let selection = dynamic(light: rgb(170, 96, 150, 0.14), dark: rgb(220, 170, 210, 0.13))
    static let pill = dynamic(light: rgb(128, 66, 78, 0.075), dark: rgb(255, 255, 255, 0.08))
    static let pillPressed = dynamic(light: rgb(128, 66, 78, 0.13), dark: rgb(255, 255, 255, 0.14))
    static let accent = dynamic(light: rgb(132, 76, 214), dark: rgb(186, 150, 255))
    static let accentFill = dynamic(light: rgb(132, 76, 214, 0.12), dark: rgb(186, 150, 255, 0.16))
    static let positive = dynamic(light: rgb(52, 168, 96), dark: rgb(90, 210, 130))
    static let caution = dynamic(light: rgb(222, 140, 40), dark: rgb(240, 170, 80))
    static let negative = dynamic(light: rgb(214, 70, 70), dark: rgb(240, 110, 110))
}

// MARK: - Window material

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct WindowBackground: View {
    var body: some View {
        ZStack {
            VisualEffect()
            LinearGradient(colors: [Palette.windowTop, Palette.windowBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Cards

struct CardSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink.opacity(0.9))
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardEdge, lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct CardDivider: View {
    var inset: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 0.5)
            .padding(.leading, inset)
            .padding(.trailing, 16)
    }
}

struct CardRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, subtitle == nil ? 12 : 10)
        .frame(minHeight: 44)
    }
}

extension CardRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, trailing: trailing)
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        CardRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
        .opacity(disabled ? 0.6 : 1)
    }
}

/// A row that opens a web page, marked with the outward arrow.
struct LinkRow: View {
    let title: String
    let symbol: String
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            CardRow(title: title) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 18)
            } trailing: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Palette.ink : Palette.inkTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Buttons

/// Raycast's tinted capsule button ("Open Theme Studio").
struct SoftButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        SoftButton(configuration: configuration, prominent: prominent)
    }

    private struct SoftButton: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? Palette.accent : Palette.ink)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? Palette.accentFill : (configuration.isPressed ? Palette.pillPressed : Palette.pill))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(hovering && !configuration.isPressed ? 0.12 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Palette.inkSecondary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(configuration.isPressed ? Palette.pillPressed : Palette.pill))
            .contentShape(Circle())
    }
}

// MARK: - Icons

/// A rounded, gradient-filled symbol tile like Raycast's sidebar icons.
struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
    }
}

/// A Slack avatar, loaded through Slack (see `IconStore`). Until it arrives,
/// or if there is none, a symbol or a coloured monogram stands in.
struct RemoteIcon: View {
    let url: String?
    var fallback: String?
    var monogram: String = ""
    var size: CGFloat = 28
    @ObservedObject private var store = IconStore.shared

    var body: some View {
        Group {
            if let url, !url.isEmpty, let image = store.image(for: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    private static let tints: [[Color]] = [
        [Color(red: 0.6, green: 0.47, blue: 0.98), Color(red: 0.44, green: 0.31, blue: 0.87)],
        [Color(red: 1, green: 0.55, blue: 0.42), Color(red: 0.92, green: 0.36, blue: 0.36)],
        [Color(red: 0.32, green: 0.72, blue: 0.96), Color(red: 0.2, green: 0.5, blue: 0.88)],
        [Color(red: 0.36, green: 0.8, blue: 0.6), Color(red: 0.18, green: 0.6, blue: 0.46)],
        [Color(red: 1, green: 0.74, blue: 0.3), Color(red: 0.94, green: 0.54, blue: 0.2)],
        [Color(red: 0.95, green: 0.5, blue: 0.74), Color(red: 0.8, green: 0.32, blue: 0.6)],
    ]

    private var tint: [Color] {
        let seed = monogram.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.tints[seed % Self.tints.count]
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom)
            if let fallback {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(monogram.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
    }
}

extension AppModel.Attachment {
    var color: Color {
        switch self {
        case .attached: return Palette.positive
        case .connecting, .restarting: return Palette.caution
        case .needsRestart, .slackNotRunning, .idle: return Palette.caution
        case .failed: return Palette.negative
        }
    }
}
