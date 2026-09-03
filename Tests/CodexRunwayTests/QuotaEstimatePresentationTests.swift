import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Quota estimate presentation")
struct QuotaEstimatePresentationTests {
    @Test("recorded token usage with zero Credits is not described as insufficient usage")
    func distinguishesCreditsUnavailableReasons() {
        let l10n = L10n(language: .simplifiedChinese)
        let zeroCredits = QuotaEstimatePresentation.unavailableText(.zeroCreditsWithUsage, l10n: l10n)
        let missingCredits = QuotaEstimatePresentation.unavailableText(.missingCredits, l10n: l10n)
        let noUsage = QuotaEstimatePresentation.unavailableText(.noUsage, l10n: l10n)

        #expect(zeroCredits.contains("Token"))
        #expect(zeroCredits.contains("Credits 返回 0"))
        #expect(!zeroCredits.contains("用量不足"))
        #expect(missingCredits.contains("未提供完整 Credits"))
        #expect(noUsage.contains("尚无用量"))
        #expect(Set([zeroCredits, missingCredits, noUsage]).count == 3)
    }

    @Test("statistics date and actual fetch time are shown independently")
    func showsStatisticsDateAndFetchTime() throws {
        let fetchedAt = try #require(ISO8601DateFormatter().date(from: "2026-09-03T04:00:00Z"))
        let quota = QuotaSnapshot(
            plan: "pro",
            primary: RateWindow(usedPercent: 47, windowMinutes: 10_080, resetsAt: fetchedAt.addingTimeInterval(4 * 86_400)),
            secondary: nil,
            additionalWindows: [],
            creditsBalance: nil,
            updatedAt: fetchedAt)
        let snapshot = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [ApiEquivalentDailyRow(date: "2026-09-02", totals: .zero, estimatedUSD: nil, rawCredits: 0)],
            mode: .auto,
            now: fetchedAt)
        let l10n = L10n(language: .english)
        let text = QuotaEstimatePresentation.dataTimeText(snapshot, l10n: l10n)

        #expect(text.contains("Statistics through 2026-09-02"))
        #expect(text.contains("Updated \(ResetCreditDateFormatter.updatedAt(fetchedAt, language: .english))"))
    }

    @Test("a failed refresh explains that displayed data is old without hiding the error")
    func keepsRefreshErrorVisible() throws {
        let l10n = L10n(language: .english)
        let text = try #require(QuotaEstimatePresentation.refreshErrorText("The request timed out", l10n: l10n))

        #expect(text.contains("previously fetched data"))
        #expect(text.contains("The request timed out"))
        #expect(QuotaEstimatePresentation.refreshErrorText(nil, l10n: l10n) == nil)
        #expect(QuotaEstimatePresentation.refreshErrorText("", l10n: l10n) == nil)
    }
}
