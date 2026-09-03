import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Quota estimate availability")
struct QuotaEstimateAvailabilityTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-03T12:00:00Z")!

    @Test("missing credits on a used day prevent extrapolation and history samples", arguments: ["", "\"credits\":null,"])
    func missingCreditsDoNotExtrapolate(creditField: String) throws {
        let snapshot = try estimate("""
        {"date":"2026-09-01","totals":{"credits":47,"uncached_text_input_tokens":1000000}},
        {"date":"2026-09-02","totals":{\(creditField)"uncached_text_input_tokens":2000000}}
        """)
        #expect(snapshot.unavailableReason == .missingCredits)
        #expect(!snapshot.creditsComplete)
        #expect(snapshot.usedCredits == 47)
        #expect(!snapshot.canExtrapolate)
        #expect(snapshot.estimatedCredits == nil)
        #expect(QuotaEstimateCalculator.sample(from: snapshot) == nil)
        #expect(try #require(snapshot.apiEquivalentUSD) > 0)
    }

    @Test("an explicitly reported zero stays zero while token cost remains available")
    func zeroCreditsWithUsageHasSpecificReason() throws {
        let snapshot = try estimate(#"{"date":"2026-09-02","totals":{"credits":0,"uncached_text_input_tokens":694950000}}"#)
        #expect(snapshot.unavailableReason == .zeroCreditsWithUsage)
        #expect(snapshot.creditsComplete)
        #expect(snapshot.currentRows.first?.creditsReported == true)
        #expect(snapshot.usedCredits == 0)
        #expect(try #require(snapshot.apiEquivalentUSD) > 0)
        #expect(QuotaEstimateCalculator.sample(from: snapshot) == nil)
    }

    @Test("a missing day is unknown rather than an unused day", arguments: ["", ",\"totals\":null"])
    func missingDayPreventsCompleteTotals(totalsField: String) throws {
        let unknownDay = "{\"date\":\"2026-09-02\"\(totalsField)}"
        let usedDay = #"{"date":"2026-09-01","totals":{"credits":47,"uncached_text_input_tokens":1000000}}"#
        for days in [unknownDay, "\(usedDay),\(unknownDay)"] {
            let snapshot = try estimate(days)
            #expect(snapshot.currentRows.last?.totalsReported == false)
            #expect(snapshot.unavailableReason == .missingCredits)
            #expect(!snapshot.creditsComplete)
            #expect(snapshot.apiEquivalentUSD == nil)
            #expect(snapshot.estimatedCredits == nil)
            #expect(QuotaEstimateCalculator.sample(from: snapshot) == nil)
        }
    }

    @Test("token-only days prevent a partial API cost from becoming the complete total")
    func partialCostIsUnavailable() throws {
        let snapshot = try estimate("""
        {"date":"2026-09-01","totals":{"credits":20,"uncached_text_input_tokens":1000000}},
        {"date":"2026-09-02","totals":{"credits":27,"text_total_tokens":2000000}}
        """)
        #expect(snapshot.currentRows.first?.usd != nil)
        #expect(snapshot.currentRows.last?.usd == nil)
        #expect(snapshot.apiEquivalentUSD == nil)
        #expect(snapshot.estimatedCredits == 100)
        #expect(snapshot.estimatedUSD == 4)
        #expect(snapshot.unavailableReason == nil)
    }

    @Test("a token-only zero-credits day has neither an invented API cost nor an allowance")
    func totalTokensAloneDoNotInventCost() throws {
        let snapshot = try estimate(#"{"date":"2026-09-02","totals":{"credits":0,"text_total_tokens":694950000}}"#)
        #expect(snapshot.currentRows.first?.tokens == 694_950_000)
        #expect(snapshot.currentRows.first?.usd == nil)
        #expect(snapshot.apiEquivalentUSD == nil)
        #expect(snapshot.unavailableReason == .zeroCreditsWithUsage)
        #expect(snapshot.estimatedCredits == nil)
    }

    @Test("positive credits retain the original formula and complete token cost total")
    func positiveCreditsKeepFormula() throws {
        let snapshot = try estimate("""
        {"date":"2026-09-01","totals":{"credits":20,"uncached_text_input_tokens":1000000}},
        {"date":"2026-09-02","totals":{"credits":27,"uncached_text_input_tokens":2000000}}
        """)
        #expect(snapshot.canExtrapolate)
        #expect(snapshot.creditsComplete)
        #expect(snapshot.unavailableReason == nil)
        #expect(snapshot.estimatedCredits == 100)
        #expect(snapshot.apiEquivalentUSD == snapshot.currentRows.compactMap(\.usd).reduce(0, +))
        #expect(snapshot.apiEquivalentUSD != snapshot.usedUSD)
        #expect(snapshot.statsThroughDate == "2026-09-02")
        #expect(snapshot.calculatedAt == now)
        #expect(QuotaEstimateCalculator.sample(from: snapshot)?.estimatedCredits == 100)
    }

    @Test("an unused row without credits does not block reported usage")
    func unusedRowDoesNotBlockReportedUsage() throws {
        let snapshot = try estimate("""
        {"date":"2026-09-01","totals":{"credits":47,"uncached_text_input_tokens":1000000}},
        {"date":"2026-09-02","totals":{"text_total_tokens":0}}
        """)
        #expect(snapshot.creditsComplete)
        #expect(snapshot.estimatedCredits == 100)
        #expect(snapshot.apiEquivalentUSD == snapshot.currentRows.first?.usd)
    }

    @Test("no usage, zero percentage, and a missing window have different reasons")
    func otherUnavailableReasons() throws {
        let empty = try estimate("")
        #expect(empty.unavailableReason == .noUsage)
        #expect(empty.statsThroughDate == nil)
        #expect(empty.apiEquivalentUSD == nil)
        let unused = try estimate(#"{"date":"2026-09-02","totals":{"credits":0,"text_total_tokens":0}}"#)
        #expect(unused.unavailableReason == .noUsage)
        let row = #"{"date":"2026-09-02","totals":{"credits":47,"text_total_tokens":1000}}"#
        #expect(try estimate(row, percent: 0).unavailableReason == .zeroPercent)
        #expect(try estimate(row, weekly: false).unavailableReason == .unavailableWindow)
    }

    @Test("legacy cached credits with unknown provenance cannot create a new estimate")
    func legacyCreditsDoNotExtrapolate() throws {
        let data = Data(#"{"data":[{"date":"2026-09-02","totals":{"credits":47,"text_total_tokens":1000}}]}"#.utf8)
        let summary = try ApiEquivalentSummary.decodeAnalytics(
            from: data, window: DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now))
        var row = try #require(summary.dailyRows.first)
        row.creditsReported = nil
        let snapshot = QuotaEstimateCalculator.make(
            quota: quota(percent: 47, weekly: true), dailyRows: [row], mode: .auto, now: now)
        #expect(snapshot.unavailableReason == .missingCredits)
        #expect(!snapshot.creditsComplete)
        #expect(QuotaEstimateCalculator.sample(from: snapshot) == nil)
    }

    private func estimate(_ days: String, percent: Int = 47, weekly: Bool = true) throws -> QuotaEstimateSnapshot {
        let summary = try ApiEquivalentSummary.decodeAnalytics(
            from: Data("{\"data\":[\(days)]}".utf8),
            window: DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now))
        return QuotaEstimateCalculator.make(
            quota: quota(percent: percent, weekly: weekly),
            dailyRows: summary.dailyRows, mode: .rollingWeek, now: now)
    }

    private func quota(percent: Int, weekly: Bool) -> QuotaSnapshot {
        QuotaSnapshot(
            plan: "pro",
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600)),
            secondary: weekly ? RateWindow(usedPercent: percent, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)) : nil,
            additionalWindows: [], creditsBalance: nil, updatedAt: now)
    }
}
