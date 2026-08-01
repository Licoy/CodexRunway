import AppKit
import CodexRunwayCore
import SwiftUI

/// Shared sheen rhythm for the badge capsule and identity text: the band travels
/// during the first `travel` seconds of each cycle, then rests — deliberate
/// sweeps instead of a continuous loop. Pure timing math; both consumers remain
/// transform/mask-only animations.
enum RunwaySheen {
    static let cycle: TimeInterval = 3.6
    static let travel: TimeInterval = 2.4

    /// 0…1 while the band travels, parked at 1 (fully exited) while resting.
    static func progress(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        return CGFloat(min(t / travel, 1))
    }
}

// NOTE: no custom TimelineSchedule here on purpose. A hand-rolled schedule that
// "sleeps" through the rest phase by advancing `cycle - phase` can compute an
// advance below Double resolution at Date magnitudes (~0.24µs at 2026 epoch),
// yielding a non-advancing entries iterator and a main-thread hang inside
// TimelineView. The stock `.animation(minimumInterval:paused:)` schedule ticks
// through the rest phase, but parked frames produce identical view values, so
// SwiftUI skips the repaint — the residual cost is one tiny body closure.

/// Metallic / plain look for a subscription tier capsule (and identity gradient text).
struct SubscriptionTierLook: Equatable {
    var foreground: Color
    /// 1–3 stop fill; single color for plain tiers.
    var fill: [Color]
    var stroke: Color
    var shimmer: Color?
    var shimmerEnabled: Bool
    /// Readable gradient stops for plain identity text (not capsule fill colors).
    var textGradient: [Color]

    static func resolve(_ tier: CodexSubscriptionTier, colorScheme: ColorScheme) -> SubscriptionTierLook {
        let light = colorScheme == .light
        switch tier {
        case .free:
            let ink = Color(nsColor: .secondaryLabelColor)
            return plain(
                foreground: ink,
                fill: light ? Color.black.opacity(0.10) : Color.white.opacity(0.14),
                stroke: Color(nsColor: .separatorColor).opacity(light ? 0.9 : 0.55),
                textGradient: [ink])
        case .plus:
            // Cool silver / white metal.
            let textGradient: [Color] = light
                ? [
                    Color(red: 0.32, green: 0.34, blue: 0.38),
                    Color(red: 0.52, green: 0.55, blue: 0.60),
                    Color(red: 0.72, green: 0.74, blue: 0.78),
                    Color(red: 0.42, green: 0.44, blue: 0.48),
                ]
                : [
                    Color(red: 0.78, green: 0.80, blue: 0.84),
                    Color(red: 0.94, green: 0.95, blue: 0.97),
                    Color(red: 1.0, green: 1.0, blue: 1.0),
                    Color(red: 0.82, green: 0.84, blue: 0.88),
                ]
            return SubscriptionTierLook(
                foreground: light
                    ? Color(red: 0.22, green: 0.24, blue: 0.28)
                    : Color(red: 0.94, green: 0.95, blue: 0.98),
                fill: light
                    ? [
                        Color(red: 0.78, green: 0.80, blue: 0.84),
                        Color(red: 0.94, green: 0.95, blue: 0.97),
                        Color(red: 0.70, green: 0.73, blue: 0.78),
                    ]
                    : [
                        Color(red: 0.42, green: 0.45, blue: 0.50),
                        Color(red: 0.72, green: 0.74, blue: 0.78),
                        Color(red: 0.38, green: 0.40, blue: 0.45),
                    ],
                stroke: light
                    ? Color(red: 0.58, green: 0.61, blue: 0.66).opacity(0.85)
                    : Color(red: 0.82, green: 0.84, blue: 0.88).opacity(0.55),
                shimmer: Color.white.opacity(light ? 0.72 : 0.55),
                shimmerEnabled: true,
                textGradient: textGradient)
        case .pro5x:
            // Classic gold — text gradient stays readable on both schemes.
            let textGradient: [Color] = light
                ? [
                    Color(red: 0.48, green: 0.32, blue: 0.04),
                    Color(red: 0.72, green: 0.52, blue: 0.10),
                    Color(red: 0.92, green: 0.72, blue: 0.22),
                    Color(red: 0.58, green: 0.40, blue: 0.06),
                ]
                : [
                    Color(red: 0.86, green: 0.66, blue: 0.22),
                    Color(red: 1.0, green: 0.88, blue: 0.45),
                    Color(red: 1.0, green: 0.96, blue: 0.72),
                    Color(red: 0.92, green: 0.74, blue: 0.30),
                ]
            return SubscriptionTierLook(
                foreground: light
                    ? Color(red: 0.35, green: 0.22, blue: 0.05)
                    : Color(red: 1.0, green: 0.92, blue: 0.62),
                fill: light
                    ? [
                        Color(red: 0.82, green: 0.62, blue: 0.18),
                        Color(red: 0.98, green: 0.86, blue: 0.42),
                        Color(red: 0.72, green: 0.52, blue: 0.12),
                    ]
                    : [
                        Color(red: 0.55, green: 0.40, blue: 0.10),
                        Color(red: 0.88, green: 0.70, blue: 0.28),
                        Color(red: 0.48, green: 0.34, blue: 0.08),
                    ],
                stroke: light
                    ? Color(red: 0.62, green: 0.44, blue: 0.10).opacity(0.9)
                    : Color(red: 0.95, green: 0.78, blue: 0.35).opacity(0.55),
                shimmer: Color(red: 1.0, green: 0.96, blue: 0.78).opacity(light ? 0.78 : 0.62),
                shimmerEnabled: true,
                textGradient: textGradient)
        case .pro20x:
            // Black-gold identity text uses bright gold gradient (not the dark capsule fill).
            let textGradient: [Color] = light
                ? [
                    Color(red: 0.42, green: 0.30, blue: 0.06),
                    Color(red: 0.72, green: 0.54, blue: 0.12),
                    Color(red: 0.95, green: 0.78, blue: 0.32),
                    Color(red: 0.55, green: 0.40, blue: 0.08),
                ]
                : [
                    Color(red: 0.78, green: 0.60, blue: 0.22),
                    Color(red: 0.96, green: 0.80, blue: 0.38),
                    Color(red: 1.0, green: 0.92, blue: 0.58),
                    Color(red: 0.88, green: 0.70, blue: 0.28),
                ]
            return SubscriptionTierLook(
                foreground: Color(red: 0.93, green: 0.78, blue: 0.38),
                fill: light
                    ? [
                        Color(red: 0.12, green: 0.11, blue: 0.10),
                        Color(red: 0.26, green: 0.22, blue: 0.16),
                        Color(red: 0.10, green: 0.09, blue: 0.08),
                    ]
                    : [
                        Color(red: 0.08, green: 0.07, blue: 0.06),
                        Color(red: 0.22, green: 0.18, blue: 0.12),
                        Color(red: 0.06, green: 0.05, blue: 0.05),
                    ],
                stroke: Color(red: 0.78, green: 0.62, blue: 0.24).opacity(light ? 0.92 : 0.75),
                shimmer: Color(red: 1.0, green: 0.88, blue: 0.48).opacity(0.70),
                shimmerEnabled: true,
                textGradient: textGradient)
        case .business:
            return steel(
                light: light,
                base: (0.10, 0.55, 0.52),
                highlight: (0.45, 0.82, 0.78),
                shadow: (0.06, 0.38, 0.36),
                textLight: (0.04, 0.28, 0.26),
                textDark: (0.72, 0.96, 0.93))
        case .team:
            return steel(
                light: light,
                base: (0.28, 0.32, 0.72),
                highlight: (0.58, 0.62, 0.95),
                shadow: (0.18, 0.20, 0.52),
                textLight: (0.12, 0.14, 0.40),
                textDark: (0.82, 0.85, 1.0))
        case .enterprise:
            return steel(
                light: light,
                base: (0.55, 0.14, 0.22),
                highlight: (0.82, 0.38, 0.42),
                shadow: (0.38, 0.08, 0.14),
                textLight: (0.32, 0.06, 0.10),
                textDark: (1.0, 0.78, 0.80))
        case .edu:
            return steel(
                light: light,
                base: (0.18, 0.52, 0.30),
                highlight: (0.48, 0.82, 0.55),
                shadow: (0.10, 0.36, 0.20),
                textLight: (0.08, 0.28, 0.14),
                textDark: (0.72, 0.96, 0.78))
        case .api:
            return steel(
                light: light,
                base: (0.12, 0.52, 0.68),
                highlight: (0.42, 0.82, 0.95),
                shadow: (0.08, 0.36, 0.48),
                textLight: (0.06, 0.28, 0.38),
                textDark: (0.70, 0.94, 1.0))
        case .unknown:
            let ink = Color(nsColor: .secondaryLabelColor)
            return plain(
                foreground: ink,
                fill: light ? Color.black.opacity(0.08) : Color.white.opacity(0.12),
                stroke: Color(nsColor: .separatorColor).opacity(light ? 0.95 : 0.55),
                textGradient: [ink])
        }
    }

    /// Grok / SuperGrok / X plan looks — same chrome language as Codex, distinct per tier.
    static func resolve(_ tier: GrokSubscriptionTier, colorScheme: ColorScheme) -> SubscriptionTierLook {
        let light = colorScheme == .light
        switch tier {
        case .free:
            let ink = Color(nsColor: .secondaryLabelColor)
            return plain(
                foreground: ink,
                fill: light ? Color.black.opacity(0.10) : Color.white.opacity(0.14),
                stroke: Color(nsColor: .separatorColor).opacity(light ? 0.9 : 0.55),
                textGradient: [ink])
        case .superGrokLite:
            // Soft sky silver — entry SuperGrok.
            return steel(
                light: light,
                base: (0.28, 0.52, 0.72),
                highlight: (0.58, 0.78, 0.95),
                shadow: (0.16, 0.36, 0.52),
                textLight: (0.10, 0.28, 0.42),
                textDark: (0.78, 0.92, 1.0))
        case .superGrok:
            // Cool silver / white metal (flagship mid tier).
            let textGradient: [Color] = light
                ? [
                    Color(red: 0.32, green: 0.34, blue: 0.38),
                    Color(red: 0.52, green: 0.55, blue: 0.60),
                    Color(red: 0.72, green: 0.74, blue: 0.78),
                    Color(red: 0.42, green: 0.44, blue: 0.48),
                ]
                : [
                    Color(red: 0.78, green: 0.80, blue: 0.84),
                    Color(red: 0.94, green: 0.95, blue: 0.97),
                    Color(red: 1.0, green: 1.0, blue: 1.0),
                    Color(red: 0.82, green: 0.84, blue: 0.88),
                ]
            return SubscriptionTierLook(
                foreground: light
                    ? Color(red: 0.22, green: 0.24, blue: 0.28)
                    : Color(red: 0.94, green: 0.95, blue: 0.98),
                fill: light
                    ? [
                        Color(red: 0.78, green: 0.80, blue: 0.84),
                        Color(red: 0.94, green: 0.95, blue: 0.97),
                        Color(red: 0.70, green: 0.73, blue: 0.78),
                    ]
                    : [
                        Color(red: 0.42, green: 0.45, blue: 0.50),
                        Color(red: 0.72, green: 0.74, blue: 0.78),
                        Color(red: 0.38, green: 0.40, blue: 0.45),
                    ],
                stroke: light
                    ? Color(red: 0.58, green: 0.61, blue: 0.66).opacity(0.85)
                    : Color(red: 0.82, green: 0.84, blue: 0.88).opacity(0.55),
                shimmer: Color.white.opacity(light ? 0.72 : 0.55),
                shimmerEnabled: true,
                textGradient: textGradient)
        case .superGrokPlus:
            // Classic gold.
            let textGradient: [Color] = light
                ? [
                    Color(red: 0.48, green: 0.32, blue: 0.04),
                    Color(red: 0.72, green: 0.52, blue: 0.10),
                    Color(red: 0.92, green: 0.72, blue: 0.22),
                    Color(red: 0.58, green: 0.40, blue: 0.06),
                ]
                : [
                    Color(red: 0.86, green: 0.66, blue: 0.22),
                    Color(red: 1.0, green: 0.88, blue: 0.45),
                    Color(red: 1.0, green: 0.96, blue: 0.72),
                    Color(red: 0.92, green: 0.74, blue: 0.30),
                ]
            return SubscriptionTierLook(
                foreground: light
                    ? Color(red: 0.35, green: 0.22, blue: 0.05)
                    : Color(red: 1.0, green: 0.92, blue: 0.62),
                fill: light
                    ? [
                        Color(red: 0.82, green: 0.62, blue: 0.18),
                        Color(red: 0.98, green: 0.86, blue: 0.42),
                        Color(red: 0.72, green: 0.52, blue: 0.12),
                    ]
                    : [
                        Color(red: 0.55, green: 0.40, blue: 0.10),
                        Color(red: 0.88, green: 0.70, blue: 0.28),
                        Color(red: 0.48, green: 0.34, blue: 0.08),
                    ],
                stroke: light
                    ? Color(red: 0.62, green: 0.44, blue: 0.10).opacity(0.9)
                    : Color(red: 0.95, green: 0.78, blue: 0.35).opacity(0.55),
                shimmer: Color(red: 1.0, green: 0.96, blue: 0.78).opacity(light ? 0.78 : 0.62),
                shimmerEnabled: true,
                textGradient: textGradient)
        case .superGrokHeavy:
            // Black-gold flagship.
            let textGradient: [Color] = light
                ? [
                    Color(red: 0.42, green: 0.30, blue: 0.06),
                    Color(red: 0.72, green: 0.54, blue: 0.12),
                    Color(red: 0.95, green: 0.78, blue: 0.32),
                    Color(red: 0.55, green: 0.40, blue: 0.08),
                ]
                : [
                    Color(red: 0.78, green: 0.60, blue: 0.22),
                    Color(red: 0.96, green: 0.80, blue: 0.38),
                    Color(red: 1.0, green: 0.92, blue: 0.58),
                    Color(red: 0.88, green: 0.70, blue: 0.28),
                ]
            return SubscriptionTierLook(
                foreground: Color(red: 0.93, green: 0.78, blue: 0.38),
                fill: light
                    ? [
                        Color(red: 0.12, green: 0.11, blue: 0.10),
                        Color(red: 0.26, green: 0.22, blue: 0.16),
                        Color(red: 0.10, green: 0.09, blue: 0.08),
                    ]
                    : [
                        Color(red: 0.08, green: 0.07, blue: 0.06),
                        Color(red: 0.22, green: 0.18, blue: 0.12),
                        Color(red: 0.06, green: 0.05, blue: 0.05),
                    ],
                stroke: Color(red: 0.78, green: 0.62, blue: 0.24).opacity(light ? 0.92 : 0.75),
                shimmer: Color(red: 1.0, green: 0.88, blue: 0.48).opacity(0.70),
                shimmerEnabled: true,
                textGradient: textGradient)
        case .xBasic:
            return steel(
                light: light,
                base: (0.18, 0.42, 0.78),
                highlight: (0.48, 0.68, 0.98),
                shadow: (0.10, 0.28, 0.58),
                textLight: (0.08, 0.22, 0.48),
                textDark: (0.75, 0.88, 1.0))
        case .xPremium:
            return steel(
                light: light,
                base: (0.42, 0.22, 0.72),
                highlight: (0.72, 0.52, 0.95),
                shadow: (0.28, 0.12, 0.52),
                textLight: (0.24, 0.10, 0.42),
                textDark: (0.90, 0.80, 1.0))
        case .xPremiumPlus:
            return steel(
                light: light,
                base: (0.62, 0.16, 0.42),
                highlight: (0.92, 0.42, 0.68),
                shadow: (0.42, 0.08, 0.28),
                textLight: (0.38, 0.06, 0.22),
                textDark: (1.0, 0.78, 0.90))
        case .apiKey:
            return steel(
                light: light,
                base: (0.12, 0.52, 0.68),
                highlight: (0.42, 0.82, 0.95),
                shadow: (0.08, 0.36, 0.48),
                textLight: (0.06, 0.28, 0.38),
                textDark: (0.70, 0.94, 1.0))
        case .unknown:
            let ink = Color(nsColor: .secondaryLabelColor)
            return plain(
                foreground: ink,
                fill: light ? Color.black.opacity(0.08) : Color.white.opacity(0.12),
                stroke: Color(nsColor: .separatorColor).opacity(light ? 0.95 : 0.55),
                textGradient: [ink])
        }
    }

    private static func plain(
        foreground: Color,
        fill: Color,
        stroke: Color,
        textGradient: [Color])
        -> SubscriptionTierLook
    {
        SubscriptionTierLook(
            foreground: foreground,
            fill: [fill],
            stroke: stroke,
            shimmer: nil,
            shimmerEnabled: false,
            textGradient: textGradient)
    }

    private static func steel(
        light: Bool,
        base: (Double, Double, Double),
        highlight: (Double, Double, Double),
        shadow: (Double, Double, Double),
        textLight: (Double, Double, Double),
        textDark: (Double, Double, Double))
        -> SubscriptionTierLook
    {
        let mid = (
            (base.0 + highlight.0) / 2,
            (base.1 + highlight.1) / 2,
            (base.2 + highlight.2) / 2)
        let fill: [Color]
        if light {
            fill = [
                Color(red: base.0, green: base.1, blue: base.2),
                Color(red: highlight.0, green: highlight.1, blue: highlight.2),
                Color(red: shadow.0, green: shadow.1, blue: shadow.2),
            ]
        } else {
            fill = [
                Color(red: shadow.0 * 0.85, green: shadow.1 * 0.85, blue: shadow.2 * 0.85),
                Color(red: mid.0 * 0.9, green: mid.1 * 0.9, blue: mid.2 * 0.9),
                Color(red: shadow.0 * 0.7, green: shadow.1 * 0.7, blue: shadow.2 * 0.7),
            ]
        }
        let foreground = light
            ? Color(red: textLight.0, green: textLight.1, blue: textLight.2)
            : Color(red: textDark.0, green: textDark.1, blue: textDark.2)
        let stroke = light
            ? Color(red: base.0, green: base.1, blue: base.2).opacity(0.85)
            : Color(red: highlight.0, green: highlight.1, blue: highlight.2).opacity(0.45)
        let shimmer = Color.white.opacity(light ? 0.55 : 0.42)
        // Identity text gradient: deep → mid → bright → mid (readable metal wash).
        let textGradient: [Color]
        if light {
            textGradient = [
                Color(red: textLight.0, green: textLight.1, blue: textLight.2),
                Color(red: base.0 * 0.85, green: base.1 * 0.85, blue: base.2 * 0.85),
                Color(red: mid.0, green: mid.1, blue: mid.2),
                Color(red: textLight.0, green: textLight.1, blue: textLight.2),
            ]
        } else {
            textGradient = [
                Color(red: textDark.0 * 0.85, green: textDark.1 * 0.85, blue: textDark.2 * 0.85),
                Color(red: mid.0, green: mid.1, blue: mid.2),
                Color(red: highlight.0, green: highlight.1, blue: highlight.2),
                Color(red: textDark.0, green: textDark.1, blue: textDark.2),
            ]
        }
        return SubscriptionTierLook(
            foreground: foreground,
            fill: fill,
            stroke: stroke,
            shimmer: shimmer,
            shimmerEnabled: true,
            textGradient: textGradient)
    }
}

/// Compact capsule for plan tiers with optional metallic sheen.
struct SubscriptionTierBadge: View {
    private enum Source: Equatable {
        case codex(CodexSubscriptionTier)
        case grok(GrokSubscriptionTier)
        case look(SubscriptionTierLook)
    }

    private var source: Source
    var label: String
    var font: Font = .caption2.weight(.semibold)
    var horizontalPadding: CGFloat = 7
    var verticalPadding: CGFloat = 3

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        tier: CodexSubscriptionTier,
        label: String,
        font: Font = .caption2.weight(.semibold),
        horizontalPadding: CGFloat = 7,
        verticalPadding: CGFloat = 3)
    {
        self.source = .codex(tier)
        self.label = label
        self.font = font
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    init(
        tier: GrokSubscriptionTier,
        label: String,
        font: Font = .caption2.weight(.semibold),
        horizontalPadding: CGFloat = 7,
        verticalPadding: CGFloat = 3)
    {
        self.source = .grok(tier)
        self.label = label
        self.font = font
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    init(
        look: SubscriptionTierLook,
        label: String,
        font: Font = .caption2.weight(.semibold),
        horizontalPadding: CGFloat = 7,
        verticalPadding: CGFloat = 3)
    {
        self.source = .look(look)
        self.label = label
        self.font = font
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    var body: some View {
        let look = resolvedLook
        Text(label)
            .font(font)
            .foregroundStyle(look.foreground)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                metallicFill(look)
            }
            .overlay {
                Capsule()
                    .strokeBorder(look.stroke, lineWidth: colorScheme == .light ? 1.0 : 0.85)
            }
            .accessibilityLabel(label)
    }

    private var resolvedLook: SubscriptionTierLook {
        switch source {
        case let .codex(tier):
            return SubscriptionTierLook.resolve(tier, colorScheme: colorScheme)
        case let .grok(tier):
            return SubscriptionTierLook.resolve(tier, colorScheme: colorScheme)
        case let .look(look):
            return look
        }
    }

    @ViewBuilder
    private func metallicFill(_ look: SubscriptionTierLook) -> some View {
        let shape = Capsule()
        ZStack {
            if look.fill.count >= 2 {
                shape.fill(
                    LinearGradient(
                        colors: look.fill,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
            } else if let only = look.fill.first {
                shape.fill(only)
            } else {
                shape.fill(Color(nsColor: .systemGray).opacity(0.16))
            }

            if look.shimmerEnabled, let shimmer = look.shimmer, !reduceMotion {
                shape
                    .fill(Color.clear)
                    .overlay {
                        SubscriptionTierFlowingSheen(color: shimmer)
                    }
                    .clipShape(shape)
            }
        }
    }
}

/// "Current account" marker: flat green capsule matching tier-badge geometry —
/// same height and baseline, but no metal relief (it marks state, not identity).
struct CurrentAccountTag: View {
    var l10n: L10n
    var horizontalPadding: CGFloat = 5
    var verticalPadding: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = RunwayTagColors.resolve(.green, colorScheme: colorScheme)
        Text(l10n.text(.accountsCurrent))
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(colors.background, in: Capsule())
            .overlay(Capsule().strokeBorder(colors.stroke, lineWidth: colorScheme == .light ? 1.0 : 0.8))
            .accessibilityLabel(l10n.text(.accountsCurrent))
    }
}

/// Identity label as plain text: callout-size semibold + tier metallic gradient (animated sheen).
struct SubscriptionTierShimmerText: View {
    var tier: CodexSubscriptionTier
    var text: String
    /// Match original identity row size; badge stays caption2.
    var font: Font = .callout.weight(.semibold)
    var truncationMode: Text.TruncationMode = .middle

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.runwayPanelVisible) private var panelVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = SubscriptionTierLook.resolve(tier, colorScheme: colorScheme)
        Group {
            if look.shimmerEnabled, look.textGradient.count >= 2, !reduceMotion {
                flowingGradientLabel(colors: look.textGradient)
            } else if look.textGradient.count >= 2 {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(truncationMode)
                    .foregroundStyle(
                        LinearGradient(
                            colors: look.textGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
            } else {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(truncationMode)
                    .foregroundStyle(look.foreground)
            }
        }
        .accessibilityLabel(text)
    }

    /// Static metal gradient text with a bright band sweeping across it via a masked
    /// overlay: glyphs rasterize once, and each animation frame is only a transform of
    /// the small band (per-frame gradient `foregroundStyle` re-rasterizes the glyphs).
    private func flowingGradientLabel(colors: [Color]) -> some View {
        let peak = sheenPeak(in: colors)
        return styledLabel
            .foregroundStyle(
                LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
            .overlay {
                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    let height = max(proxy.size.height, 1)
                    let bandWidth = max(24, width * 0.3)
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !panelVisible)) { context in
                        let t = RunwaySheen.progress(at: context.date)
                        // Travel with overshoot so the tilted band fully enters/exits.
                        let travel = width + bandWidth * 2
                        LinearGradient(
                            colors: [
                                peak.opacity(0),
                                peak.opacity(colorScheme == .light ? 0.70 : 0.85),
                                peak.opacity(0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing)
                            .frame(width: bandWidth, height: height * 2.5)
                            .rotationEffect(.degrees(24))
                            .offset(x: -bandWidth + t * travel, y: -height * 0.75)
                    }
                }
                .mask(styledLabel)
                .allowsHitTesting(false)
            }
    }

    /// Shared glyph styling for the visible label and the sheen mask (must match exactly).
    private var styledLabel: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .truncationMode(truncationMode)
    }

    /// Light mode: peak stays within the metal palette (pure white washes out on light UI).
    /// Dark mode: a short white peak sells the sheen without killing contrast.
    private func sheenPeak(in colors: [Color]) -> Color {
        if colorScheme == .light {
            return colors.count >= 3 ? colors[2] : (colors.first ?? .white)
        }
        return .white
    }
}

/// Metallic slash that travels along the top-leading → bottom-trailing diagonal,
/// sweeping once per RunwaySheen cycle and resting between passes.
private struct SubscriptionTierFlowingSheen: View {
    var color: Color
    @Environment(\.runwayPanelVisible) private var panelVisible

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = max(proxy.size.height, 1)
            // Thin along the path; long enough to cover the host when rotated.
            let bandWidth = max(10, min(16, width * 0.22))
            let bandLength = max(height, width) * 2.4
            // Path angle of the host diagonal (TL → BR).
            let pathDegrees = Double(atan2(height, width)) * 180 / .pi
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !panelVisible)) { context in
                let t = RunwaySheen.progress(at: context.date)
                // Parametric travel along TL → BR, with overshoot so the band fully enters/exits.
                let margin = max(bandWidth, height) * 1.15
                let x = -margin + t * (width + margin * 2)
                let y = -margin + t * (height + margin * 2)
                ZStack {
                    LinearGradient(
                        colors: [
                            color.opacity(0),
                            color.opacity(0.28),
                            color,
                            color.opacity(0.28),
                            color.opacity(0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing)
                        .frame(width: bandWidth, height: bandLength)
                        // Align the band so its thin axis follows the TL→BR path.
                        .rotationEffect(.degrees(pathDegrees))
                        // Translate from center via `.offset`: `.position` is a layout
                        // modifier and would relayout the subtree every frame.
                        .offset(x: x - width / 2, y: y - height / 2)
                }
                .frame(width: width, height: height)
            }
        }
        .allowsHitTesting(false)
    }
}

extension SubscriptionTierBadge {
    /// Localized label for every known Codex tier.
    static func localizedTitle(for tier: CodexSubscriptionTier, l10n: L10n) -> String {
        switch tier {
        case .free: return l10n.text(.planFree)
        case .plus: return l10n.text(.planPlus)
        case .pro5x: return l10n.text(.planPro5x)
        case .pro20x: return l10n.text(.planPro20x)
        case .business: return l10n.text(.planBusiness)
        case .team: return l10n.text(.planTeam)
        case .enterprise: return l10n.text(.planEnterprise)
        case .edu: return l10n.text(.planEdu)
        case .api: return l10n.text(.planAPI)
        case .unknown: return l10n.text(.planUnknown)
        }
    }

    /// Label for Grok tiers. Brand names stay English; free/unknown use L10n.
    static func localizedTitle(for tier: GrokSubscriptionTier, planRaw: String? = nil, l10n: L10n) -> String {
        switch tier {
        case .free:
            return l10n.text(.planFree)
        case .unknown:
            if let raw = planRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                return GrokSubscriptionTier.displayName(from: raw) ?? raw
            }
            return l10n.text(.planUnknown)
        default:
            return tier.displayName
        }
    }
}
