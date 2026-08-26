import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Quota estimate")
struct QuotaEstimateTests {
    private let now = Date(timeIntervalSince1970: 1_782_710_400) // 2026-06-29T12:00:00Z

    @Test("picks secondary weekly window over 5-hour primary")
    func picksSecondaryWeeklyWindow() throws {
        let quota = snapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3 * 86_400)))

        let weekly = try #require(QuotaEstimateCalculator.weeklyWindow(from: quota))
        #expect(weekly.usedPercent == 40)
        #expect(QuotaEstimateCalculator.isWeekly(weekly))
    }

    @Test("picks primary when it is the weekly window")
    func picksPrimaryWeeklyWindow() throws {
        let quota = snapshot(
            primary: RateWindow(usedPercent: 22, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(2 * 86_400)),
            secondary: RateWindow(usedPercent: 5, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600)))

        let weekly = try #require(QuotaEstimateCalculator.weeklyWindow(from: quota))
        #expect(weekly.windowMinutes == 10_080)
    }

    @Test("does not treat a 5-hour window as weekly")
    func fiveHourIsNotWeekly() {
        let quota = snapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            secondary: nil)

        #expect(QuotaEstimateCalculator.weeklyWindow(from: quota) == nil)
        let rolling = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [day("2026-06-29", credits: 12)],
            mode: .rollingWeek,
            now: now)
        #expect(!rolling.canExtrapolate)
        #expect(rolling.estimatedCredits == nil)
        #expect(rolling.usedCredits == 12)
    }

    @Test("auto mode uses the official cycle of the selected meter")
    func autoUsesOfficialCycleNotRollingSevenDays() throws {
        let reset = Date(timeIntervalSince1970: 1_783_315_200) // 2026-07-06T12:00:00Z
        let quota = snapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now),
            secondary: RateWindow(
                usedPercent: 3,
                windowMinutes: 10_080,
                resetsAt: reset))
        let estimate = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [
                day("2026-06-22", credits: 50_000),
                day("2026-06-28", credits: 20_000),
                day("2026-06-29", credits: 3_379.6),
            ],
            mode: .auto,
            now: now)

        #expect(estimate.cycleStartDate == "2026-06-29")
        #expect(estimate.usedCredits == 3_379.6)
        #expect(estimate.usedPercent == 3)
        let estimated = try #require(estimate.estimatedCredits)
        #expect(abs(estimated - 3_379.6 / 0.03) < 0.01)
        let usd = try #require(estimate.estimatedUSD)
        #expect(abs(usd - (3_379.6 / 0.03) * 0.04) < 0.01)
    }

    @Test("rolling week starts six UTC days before the latest daily row")
    func rollingWeekUsesLatestDailyDate() {
        let quota = weeklyQuota(usedPercent: 25)
        let estimate = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [
                day("2026-06-20", credits: 9),
                day("2026-06-22", credits: 10),
                day("2026-06-29", credits: 15),
            ],
            mode: .rollingWeek,
            now: now)

        #expect(estimate.cycleStartDate == "2026-06-23")
        #expect(estimate.currentRows.map(\.date) == ["2026-06-29"])
        #expect(estimate.usedCredits == 15)
        #expect(estimate.estimatedCredits == 60)
        #expect(estimate.estimatedUSD == 2.4)
    }

    @Test("auto week uses reset minus window length")
    func autoUsesResetAnchor() {
        let reset = Date(timeIntervalSince1970: 1_783_315_200) // 2026-07-06T12:00:00Z
        let quota = snapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now),
            secondary: RateWindow(
                usedPercent: 50,
                windowMinutes: 10_080,
                resetsAt: reset))
        let estimate = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [
                day("2026-06-28", credits: 5),
                day("2026-06-29", credits: 15),
                day("2026-07-01", credits: 20),
            ],
            mode: .auto,
            now: now)

        #expect(estimate.cycleStartDate == "2026-06-29")
        #expect(estimate.usedCredits == 35)
        #expect(estimate.estimatedCredits == 70)
    }

    @Test("does not extrapolate when used percent is zero")
    func zeroPercentDoesNotExtrapolate() {
        let quota = weeklyQuota(usedPercent: 0)
        let estimate = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [day("2026-06-29", credits: 8)],
            mode: .rollingWeek,
            now: now)
        #expect(!estimate.canExtrapolate)
        #expect(estimate.estimatedCredits == nil)
        #expect(estimate.usedCredits == 8)
    }

    @Test("does not extrapolate when current-cycle credits are zero")
    func zeroCreditsDoesNotExtrapolate() {
        let quota = weeklyQuota(usedPercent: 20)
        let estimate = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [day("2026-06-29", credits: 0)],
            mode: .rollingWeek,
            now: now)
        #expect(!estimate.canExtrapolate)
        #expect(estimate.estimatedCredits == nil)
    }

    @Test("uses exact used percent for extrapolation")
    func usesExactUsedPercent() {
        let quota = snapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: now),
            secondary: RateWindow(
                usedPercent: 12,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(86_400),
                usedPercentExact: 12.5))
        let estimate = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [day("2026-06-29", credits: 25)],
            mode: .rollingWeek,
            now: now)
        #expect(estimate.usedPercent == 12.5)
        #expect(estimate.estimatedCredits == 200)
    }

    @Test("same-cycle history is not treated as a cut")
    func sameCycleHistoryDoesNotCompare() {
        let quota = weeklyQuota(usedPercent: 40)
        let sample = QuotaEstimateHistorySample(
            cycleStartDate: "2026-06-23",
            estimatedCredits: 250,
            usedPercent: 40,
            usedCredits: 100,
            recordedAt: now.addingTimeInterval(-3_600))
        let estimate = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [day("2026-06-29", credits: 80)],
            mode: .rollingWeek,
            history: [sample],
            now: now)
        #expect(estimate.cycleStartDate == "2026-06-23")
        #expect(estimate.estimatedCredits == 200)
        #expect(estimate.previousEstimate == nil)
        #expect(estimate.changeKind == nil)
    }

    @Test("marks a cut when the new cycle estimate drops at least 10 percent")
    func marksSignificantDecrease() throws {
        let quota = weeklyQuota(usedPercent: 50)
        let previous = QuotaEstimateHistorySample(
            cycleStartDate: "2026-06-16",
            estimatedCredits: 200,
            usedPercent: 80,
            usedCredits: 160,
            recordedAt: now.addingTimeInterval(-7 * 86_400))
        let estimate = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [day("2026-06-29", credits: 80)],
            mode: .rollingWeek,
            history: [previous],
            now: now)
        #expect(estimate.estimatedCredits == 160)
        #expect(estimate.changeKind == .decreased)
        let change = try #require(estimate.changePercent)
        #expect(change == -20)
    }

    @Test("ignores sub-threshold jitter against the previous cycle")
    func similarChangeStaysQuiet() {
        let quota = weeklyQuota(usedPercent: 50)
        let previous = QuotaEstimateHistorySample(
            cycleStartDate: "2026-06-16",
            estimatedCredits: 200,
            usedPercent: 40,
            usedCredits: 80,
            recordedAt: now.addingTimeInterval(-7 * 86_400))
        let estimate = QuotaEstimateCalculator.make(
            quota: quota,
            dailyRows: [day("2026-06-29", credits: 96)],
            mode: .rollingWeek,
            history: [previous],
            now: now)
        #expect(estimate.estimatedCredits == 192)
        #expect(estimate.changeKind == .similar)
    }

    @Test("history store upserts the same cycle and keeps twelve weeks")
    func historyStoreUpsertsAndCaps() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-estimate-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QuotaEstimateHistoryStore(fileURL: url)
        let key = "oauth:user:abc|account:acct"

        for index in 0..<14 {
            let day = String(format: "2026-05-%02d", index + 1)
            _ = store.upsert(
                accountKey: key,
                sample: QuotaEstimateHistorySample(
                    cycleStartDate: day,
                    estimatedCredits: Double(100 + index),
                    usedPercent: 40,
                    usedCredits: 40,
                    recordedAt: now.addingTimeInterval(Double(index) * 60)))
        }
        let first = store.load(accountKey: key)
        #expect(first.count == 12)
        #expect(first.first?.cycleStartDate == "2026-05-03")
        #expect(first.last?.cycleStartDate == "2026-05-14")

        let updated = store.upsert(
            accountKey: key,
            sample: QuotaEstimateHistorySample(
                cycleStartDate: "2026-05-14",
                estimatedCredits: 50,
                usedPercent: 20,
                usedCredits: 10,
                recordedAt: now.addingTimeInterval(1_000)))
        #expect(updated.last?.estimatedCredits == 50)
        #expect(store.load(accountKey: "other").isEmpty)
    }

    @Test("compact token formatting matches the reference script")
    func compactTokens() {
        #expect(QuotaEstimateCalculator.compactTokens(12) == "12")
        #expect(QuotaEstimateCalculator.compactTokens(1_500) == "1.50K")
        #expect(QuotaEstimateCalculator.compactTokens(2_250_000) == "2.25M")
    }

    @Test("decodes fractional used_percent onto usedPercentExact")
    func decodesFractionalUsedPercent() throws {
        let data = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {"used_percent": 12.4, "reset_at": 1782711351, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": "40.5", "reset_at": 1783298151, "limit_window_seconds": 604800}
          }
        }
        """.data(using: .utf8)!

        let snapshot = try QuotaSnapshot.decode(from: data, now: now)
        #expect(snapshot.primary.usedPercentExact == 12.4)
        #expect(snapshot.primary.usedPercent == 12)
        #expect(snapshot.secondary?.usedPercentExact == 40.5)
        #expect(snapshot.secondary?.usedPercent == 41)
    }

    private func weeklyQuota(usedPercent: Int) -> QuotaSnapshot {
        snapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            secondary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(3 * 86_400)))
    }

    private func snapshot(primary: RateWindow, secondary: RateWindow?) -> QuotaSnapshot {
        QuotaSnapshot(
            plan: "pro",
            primary: primary,
            secondary: secondary,
            additionalWindows: [],
            creditsBalance: nil,
            updatedAt: now)
    }

    private func day(_ date: String, credits: Double) -> ApiEquivalentDailyRow {
        ApiEquivalentDailyRow(
            date: date,
            totals: ApiEquivalentTotals(
                totalTokens: Int(credits * 1_000),
                uncachedInputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                turns: 2,
                threads: 1),
            estimatedUSD: nil,
            rawCredits: credits)
    }
}
