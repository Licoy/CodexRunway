import AppKit
import CodexRunwayCore
import SwiftUI

struct RateLimitResetTodayReactionButton: View {
    var snapshot: RateLimitResetTodayReactionSnapshot
    var l10n: L10n
    var isBusy: Bool
    var delta: RateLimitResetTodayReactionDelta
    var onClick: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floatingDelta = 0
    @State private var floatVisible = false
    @State private var isHovered = false

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 4) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text(emoji)
                        .font(.caption)
                }
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(countText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(border, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if floatingDelta > 0 {
                    Text(RateLimitResetTodayReaction.formatDelta(floatingDelta, language: l10n.language))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .offset(y: reduceMotion ? -2 : (floatVisible ? -12 : 0))
                        .opacity(floatVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(snapshot.isExhausted && !isBusy ? 0.45 : 1)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("rate-limit-reset-today-reaction")
        .pointingHandCursor(enabled: !isDisabled)
        .onHover { hovering in
            isHovered = hovering && !isDisabled
        }
        .onChange(of: isDisabled) { disabled in
            if disabled { isHovered = false }
        }
        .onChange(of: delta.id) { _ in
            presentDelta(delta.amount)
        }
    }

    private var isDisabled: Bool {
        isBusy || snapshot.isExhausted
    }

    private var emoji: String {
        snapshot.polarity == .yes ? "🎉" : "🙏"
    }

    private var label: String {
        l10n.text(snapshot.polarity == .yes
            ? .rateLimitResetTodayReactionThank
            : .rateLimitResetTodayReactionPlease)
    }

    private var countText: String {
        RateLimitResetTodayReaction.formatCount(snapshot.count ?? 0, language: l10n.language)
    }

    private var showHover: Bool { isHovered && !isDisabled }

    private var foreground: Color {
        if snapshot.polarity == .yes {
            return Color(nsColor: .systemGreen)
        }
        return Color(nsColor: .labelColor)
    }

    private var fill: Color {
        if !showHover { return RunwaySurface.raised }
        if snapshot.polarity == .yes {
            return Color(nsColor: .systemGreen).opacity(0.16)
        }
        return RunwaySurface.hoverNeutral
    }

    private var border: Color {
        if snapshot.polarity == .yes {
            return Color(nsColor: .systemGreen).opacity(showHover ? 0.95 : 0.55)
        }
        return showHover ? Color.primary.opacity(0.35) : RunwaySurface.hairline
    }

    private var accessibilityLabel: String {
        if snapshot.isExhausted && !isBusy {
            return l10n.text(.rateLimitResetTodayReactionLimitReached)
        }
        let key: L10nKey = snapshot.polarity == .yes
            ? .rateLimitResetTodayReactionThankAria
            : .rateLimitResetTodayReactionPleaseAria
        return String(format: l10n.text(key), countText)
    }

    private func presentDelta(_ value: Int) {
        guard value > 0 else { return }
        floatingDelta = value
        let motion = reduceMotion ? Animation.easeOut(duration: 0.2) : .easeOut(duration: 1)
        withAnimation(motion) {
            floatVisible = true
        }
        let token = value
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard floatingDelta == token else { return }
            withAnimation(motion) {
                floatVisible = false
            }
        }
    }
}
