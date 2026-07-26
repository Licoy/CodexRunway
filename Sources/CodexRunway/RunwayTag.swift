import AppKit
import SwiftUI

/// Semantic capsule-tag tints shared by subscription badges, expiry chips, and status pills.
enum RunwayTagTone: Equatable {
    case neutral
    case gray
    case blue
    case purple
    case orange
    case yellow
    case green
    case red
    case teal
    case indigo
    case cyan
}

/// Resolved light/dark-safe colors for a capsule tag.
struct RunwayTagColors: Equatable {
    var foreground: Color
    var background: Color
    var stroke: Color

    static func resolve(_ tone: RunwayTagTone, colorScheme: ColorScheme) -> RunwayTagColors {
        let light = colorScheme == .light
        switch tone {
        case .neutral:
            // Soft chip: dark text on gray fill (not tint-on-tint).
            return RunwayTagColors(
                foreground: Color(nsColor: light ? .labelColor : .secondaryLabelColor),
                background: light
                    ? Color.black.opacity(0.08)
                    : Color.white.opacity(0.14),
                stroke: Color(nsColor: .separatorColor).opacity(light ? 0.95 : 0.65))
        default:
            return tinted(tone, light: light)
        }
    }

    private static func tinted(_ tone: RunwayTagTone, light: Bool) -> RunwayTagColors {
        let tint = baseTint(tone, light: light)
        if light {
            // Light: soft wash + deep ink — solid saturated chips read as paint blobs.
            return RunwayTagColors(
                foreground: deepInk(tone),
                background: tint.opacity(0.14),
                stroke: tint.opacity(0.35))
        }
        return RunwayTagColors(
            foreground: tint,
            background: tint.opacity(0.22),
            stroke: tint.opacity(0.42))
    }

    /// Deep, readable ink for light-mode tags (same hue family as the tint).
    private static func deepInk(_ tone: RunwayTagTone) -> Color {
        switch tone {
        case .green:
            return Color(red: 0.06, green: 0.36, blue: 0.18)
        case .orange, .yellow:
            return Color(red: 0.62, green: 0.30, blue: 0.02)
        case .red:
            return Color(red: 0.58, green: 0.10, blue: 0.12)
        case .blue:
            return Color(red: 0.08, green: 0.24, blue: 0.52)
        case .purple:
            return Color(red: 0.34, green: 0.14, blue: 0.48)
        case .teal:
            return Color(red: 0.04, green: 0.32, blue: 0.36)
        case .indigo:
            return Color(red: 0.16, green: 0.18, blue: 0.46)
        case .cyan:
            return Color(red: 0.05, green: 0.30, blue: 0.42)
        case .neutral, .gray:
            return Color(red: 0.22, green: 0.24, blue: 0.28)
        }
    }

    private static func baseTint(_ tone: RunwayTagTone, light: Bool = false) -> Color {
        switch tone {
        case .neutral:
            return Color(nsColor: .secondaryLabelColor)
        case .gray:
            return Color(nsColor: .systemGray)
        case .yellow:
            // Pure systemYellow washes out; orange stays readable for warnings.
            return Color(nsColor: light ? .systemOrange : .systemYellow)
        case .blue:
            return Color(nsColor: .systemBlue)
        case .purple:
            return Color(nsColor: .systemPurple)
        case .orange:
            return Color(nsColor: .systemOrange)
        case .green:
            return Color(nsColor: .systemGreen)
        case .red:
            return Color(nsColor: .systemRed)
        case .teal:
            return Color(nsColor: .systemTeal)
        case .indigo:
            return Color(nsColor: .systemIndigo)
        case .cyan:
            return Color(nsColor: .systemCyan)
        }
    }
}

/// Compact capsule label used for plan tiers, subscription expiry, and credit status.
struct RunwayTag<Content: View>: View {
    var tone: RunwayTagTone
    var font: Font = .caption2.weight(.semibold)
    var horizontalPadding: CGFloat = 7
    var verticalPadding: CGFloat = 3
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = RunwayTagColors.resolve(tone, colorScheme: colorScheme)
        content()
            .font(font)
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(colors.background, in: Capsule())
            .overlay(Capsule().strokeBorder(colors.stroke, lineWidth: colorScheme == .light ? 1.0 : 0.8))
            .lineLimit(1)
    }
}

extension RunwayTag where Content == Text {
    init(
        _ title: String,
        tone: RunwayTagTone,
        font: Font = .caption2.weight(.semibold),
        horizontalPadding: CGFloat = 7,
        verticalPadding: CGFloat = 3)
    {
        self.tone = tone
        self.font = font
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = { Text(title) }
    }
}
