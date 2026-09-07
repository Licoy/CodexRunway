import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Subscription expiry badge")
@MainActor
struct SubscriptionExpiryBadgeTests {
    nonisolated private static let countdownCases: [(TimeInterval, L10nKey)] = [
        (-7 * 86_400.0 - 1, L10nKey.subscriptionExpires),
        (-7 * 86_400.0, L10nKey.subscriptionExpiringSoon),
        (-1.0, L10nKey.subscriptionExpiringSoon),
        (0.0, L10nKey.subscriptionExpired),
        (4 * 3_600.0, L10nKey.subscriptionExpired),
    ]

    @Test("badge countdown and status use the supplied expiry instant", arguments: countdownCases)
    func exactCountdown(example: (TimeInterval, L10nKey)) throws {
        let (elapsed, status) = example
        let expiry = try #require(RunwayDates.parse("2026-09-07T20:30:00Z"))
        let l10n = L10n(language: .english)
        let badge = SubscriptionExpiryBadge(
            expiresAt: expiry, l10n: l10n, now: expiry.addingTimeInterval(elapsed))

        #expect(badge.remainingSeconds == max(0, -elapsed))
        #expect(badge.statusLabel == l10n.text(status))
        if elapsed >= 0 {
            #expect(badge.accessibilityText == "\(l10n.text(.subscriptionExpired)) \(badge.helpText)")
        } else {
            #expect(badge.accessibilityText.hasSuffix(
                DurationFormatter.localized(-elapsed, language: .english, includeSeconds: false)))
        }
    }

    @Test("tooltip and accessibility include localized full expiry", arguments: ResolvedLanguage.allCases)
    func localTimeHelp(language: ResolvedLanguage) throws {
        let expiry = try #require(RunwayDates.parse("2026-09-07T20:30:00Z"))
        let l10n = L10n(language: language)
        let badge = SubscriptionExpiryBadge(expiresAt: expiry, l10n: l10n, now: expiry)
        let localTime = SubscriptionDateFormatter.expiresAt(expiry, language: language)

        #expect(badge.helpText == String(format: l10n.text(.subscriptionExpiryLocalTime), localTime))
        #expect(!badge.helpText.contains("%@"))
        #expect(badge.helpText.contains(TimeZone.autoupdatingCurrent.identifier))
        #expect(badge.accessibilityText.contains(badge.helpText))
    }
}
