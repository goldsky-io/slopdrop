import SwiftUI

/// Picker of visual previews, one per style — the Raycast "Window Mode" tiles.
struct StyleGallery: View {
    let styles: [StyleDescriptor]
    @Binding var selection: String

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(styles) { style in
                StyleTile(style: style, selected: style.id == selection) { selection = style.id }
            }
        }
        .padding(16)
    }
}

private struct StyleTile: View {
    let style: StyleDescriptor
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                StylePreview(styleID: style.id)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Palette.accent : Palette.cardEdge, lineWidth: selected ? 2 : 0.5)
                    )
                    .shadow(color: .black.opacity(hovering ? 0.1 : 0.05), radius: hovering ? 6 : 3, y: hovering ? 3 : 1)
                    .scaleEffect(hovering ? 1.015 : 1)
                    .animation(.easeOut(duration: 0.15), value: hovering)

                Text(style.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Palette.ink : Palette.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(selected ? Palette.selection : .clear))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(style.blurb)
        .accessibilityLabel("\(style.title) style")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tiny Slack timeline: one ordinary message for context, then an app
/// message drawn the way the style renders it.
struct StylePreview: View {
    let styleID: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.93, green: 0.86, blue: 0.98), Color(red: 0.99, green: 0.87, blue: 0.82)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 7) {
                MiniMessage(avatar: [Color(red: 1, green: 0.62, blue: 0.38), Color(red: 0.95, green: 0.42, blue: 0.4)], nameWidth: 30, lines: [0.78, 0.5])
                affected
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.92)))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, -6)
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        }
        .environment(\.colorScheme, .light)
    }

    private let appAvatar = [Color(red: 0.6, green: 0.48, blue: 0.95), Color(red: 0.44, green: 0.34, blue: 0.86)]

    @ViewBuilder private var affected: some View {
        switch styleID {
        case "accordion":
            MiniMessage(avatar: appAvatar, nameWidth: 26, app: true, lines: [0.62], chip: .neutral)
        case "blur":
            MiniMessage(avatar: appAvatar, nameWidth: 26, app: true, lines: [0.9, 0.7, 0.55], frosted: true)
        case "dim":
            MiniMessage(avatar: appAvatar, nameWidth: 26, app: true, lines: [0.9, 0.7], card: true).opacity(0.28)
        case "monochrome":
            MiniMessage(avatar: appAvatar, nameWidth: 26, app: true, lines: [0.9, 0.7], card: true).saturation(0).opacity(0.5)
        case "outline":
            MiniMessage(avatar: appAvatar, nameWidth: 26, app: true, lines: [0.9, 0.7], chip: .accent, card: true)
                .padding(.leading, 5)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Palette.accent.opacity(0.8)).frame(width: 2)
                }
        case "hide":
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.black.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 22)
                .overlay(
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.3))
                )
        default:
            MiniMessage(avatar: appAvatar, nameWidth: 26, app: true, lines: [0.9, 0.7])
        }
    }
}

private struct MiniMessage: View {
    enum Chip { case neutral, accent }

    let avatar: [Color]
    let nameWidth: CGFloat
    var app = false
    let lines: [CGFloat]
    var chip: Chip?
    var frosted = false
    /// The card Dim, Grayscale and Tag put the body in, with its "Show more".
    var card = false

    private let ink = Color(red: 0.11, green: 0.1, blue: 0.11)

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(LinearGradient(colors: avatar, startPoint: .top, endPoint: .bottom))
                .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Capsule().fill(ink.opacity(0.75)).frame(width: nameWidth, height: 4.5)
                    if app {
                        RoundedRectangle(cornerRadius: 1.5).fill(ink.opacity(0.14)).frame(width: 10, height: 5)
                    }
                    Capsule().fill(ink.opacity(0.25)).frame(width: 11, height: 3.5)
                    if let chip {
                        Capsule()
                            .fill(chip == .accent ? Palette.accent.opacity(0.18) : ink.opacity(0.07))
                            .overlay(Capsule().strokeBorder(ink.opacity(0.08), lineWidth: 0.5))
                            .frame(width: 22, height: 7)
                    }
                }
                if card {
                    VStack(alignment: .leading, spacing: 4) {
                        bodyLines
                        Capsule().fill(Color(red: 0.07, green: 0.39, blue: 0.64).opacity(0.75)).frame(width: 15, height: 3)
                    }
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ink.opacity(0.16), lineWidth: 0.6))
                } else {
                    bodyLines
                }
            }
        }
    }

    private var bodyLines: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 3.5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, fraction in
                    Capsule()
                        .fill(index == 1 ? Color(red: 0.16, green: 0.42, blue: 0.8).opacity(0.45) : ink.opacity(0.28))
                        .frame(width: geo.size.width * fraction, height: 3.5)
                }
            }
            .blur(radius: frosted ? 1.6 : 0)
            .overlay(alignment: .topLeading) {
                if frosted {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ink.opacity(0.07), lineWidth: 0.5))
                        .overlay(alignment: .topLeading) {
                            Capsule().fill(Color.white).frame(width: 24, height: 6)
                                .overlay(Capsule().strokeBorder(ink.opacity(0.08), lineWidth: 0.5))
                                .padding(3)
                        }
                        .padding(-3)
                }
            }
        }
        .frame(height: CGFloat(lines.count) * 7)
    }
}
