import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Quota estimate analytics")
struct QuotaEstimateAnalyticsTests {
    @Test("analytics distinguishes missing credits from an explicitly reported zero")
    func distinguishesCreditPresence() throws {
        let summary = try decode("""
        {"data":[
          {"date":"2026-09-01","totals":{"text_total_tokens":451770000}},
          {"date":"2026-09-02","totals":{"credits":null,"text_total_tokens":21990000}},
          {"date":"2026-09-03","totals":{"credits":0,"uncached_text_input_tokens":1000000}},
          {"date":"2026-09-04","totals":{"credits":"12.5"}},
          {"date":"2026-09-05"},
          {"date":"2026-09-06","totals":null}
        ]}
        """)

        #expect(summary.dailyRows.map(\.rawCredits) == [0, 0, 0, 12.5, 0, 0])
        #expect(try summary.dailyRows.map(reportedCredits) == [false, false, true, true, false, false])
        #expect(summary.dailyRows[0].totals.totalTokens == 451_770_000)
        #expect(summary.dailyRows[2].estimatedUSD == Decimal(5))
    }

    @Test("analytics accepts numeric credits including numeric strings", arguments: ["0", "12.5", #""0""#, #""12.5""#])
    func acceptsNumericCredits(_ value: String) throws {
        let summary = try decode("""
        {"data":[{"date":"2026-09-01","totals":{"credits":\(value)}}]}
        """)
        let row = try #require(summary.dailyRows.first)

        #expect(try reportedCredits(row) == true)
        #expect(row.rawCredits == (value.contains("12.5") ? 12.5 : 0))
    }

    @Test("analytics rejects negative, invalid, and non-finite credits", arguments: [
        "-1", #""-0.5""#, "true", "{}", "[]", #""NaN""#, #""inf""#, #""invalid""#,
    ])
    func rejectsInvalidCredits(_ value: String) {
        #expect(throws: (any Error).self) {
            try decode("""
            {"data":[{"date":"2026-09-01","totals":{"credits":\(value)}}]}
            """)
        }
    }

    @Test("analytics rejects invalid credits in model and client breakdowns", arguments: ["models", "clients"])
    func rejectsInvalidBreakdownCredits(_ breakdown: String) {
        #expect(throws: (any Error).self) {
            try decode("""
            {"data":[{"date":"2026-09-01","\(breakdown)":[{"name":"test","credits":-1}]}]}
            """)
        }
    }

    @Test("analytics does not report a complete cost when a used day has no token parts")
    func partialDailyPricingIsUnavailableForTotal() throws {
        let summary = try decode("""
        {"data":[
          {"date":"2026-09-01","totals":{"credits":0,"uncached_text_input_tokens":1000000}},
          {"date":"2026-09-02","totals":{"credits":0,"text_total_tokens":2000000}}
        ]}
        """)

        #expect(summary.dailyRows[0].estimatedUSD == Decimal(5))
        #expect(summary.dailyRows[1].estimatedUSD == nil)
        #expect(summary.estimatedUSD == nil)
        #expect(summary.confidence == .tokensOnly)
        #expect(summary.warnings.contains("analytics-token-parts-missing"))
        #expect(summary.totals.totalTokens == 3_000_000)
    }

    @Test("an omitted or null daily total prevents a complete cost", arguments: ["", #","totals":null"#])
    func missingDailyTotalsPreventCompleteCost(_ totalsField: String) throws {
        let summary = try decode("""
        {"data":[
          {"date":"2026-09-01","totals":{"credits":47,"uncached_text_input_tokens":1000000}},
          {"date":"2026-09-02"\(totalsField)}
        ]}
        """)

        #expect(try summary.dailyRows.map(reportedTotals) == [true, false])
        #expect(summary.dailyRows[0].estimatedUSD == Decimal(5))
        #expect(summary.dailyRows[1].estimatedUSD == nil)
        #expect(summary.estimatedUSD == nil)
        #expect(summary.confidence == .tokensOnly)
        #expect(summary.warnings.contains("analytics-token-parts-missing"))
    }

    @Test("a day without totals stays unavailable instead of reporting a zero cost", arguments: ["", #","totals":null"#])
    func missingDailyTotalsStayUnavailable(_ totalsField: String) throws {
        let summary = try decode("""
        {"data":[{"date":"2026-09-01"\(totalsField)}]}
        """)
        let row = try #require(summary.dailyRows.first)

        #expect(try reportedTotals(row) == false)
        #expect(try reportedCredits(row) == false)
        #expect(row.estimatedUSD == nil)
        #expect(summary.estimatedUSD == nil)
        #expect(summary.confidence == .unavailable)
        #expect(summary.warnings.contains("analytics-token-parts-missing"))
    }

    @Test("an unused day does not invalidate a complete API equivalent cost")
    func zeroTokenDayPreservesCompleteCost() throws {
        let summary = try decode("""
        {"data":[
          {"date":"2026-09-01","totals":{"credits":0,"uncached_text_input_tokens":1000000}},
          {"date":"2026-09-02","totals":{"credits":0,"text_total_tokens":0}}
        ]}
        """)

        #expect(summary.estimatedUSD == Decimal(5))
        #expect(summary.confidence == .priced)
        #expect(summary.warnings.isEmpty)
    }

    @Test("old cached daily rows keep their credits reporting status unknown")
    func oldCacheKeepsUnknownCreditPresence() throws {
        let data = Data("""
        {"date":"2026-09-01","rawCredits":0,"totals":{
          "totalTokens":451770000,"uncachedInputTokens":0,"cachedInputTokens":0,
          "outputTokens":0,"turns":1,"threads":1
        }}
        """.utf8)
        let row = try JSONDecoder().decode(ApiEquivalentDailyRow.self, from: data)
        let restored = try JSONDecoder().decode(ApiEquivalentDailyRow.self, from: JSONEncoder().encode(row))

        #expect(try reportedCredits(row) == nil)
        #expect(try reportedTotals(row) == nil)
        #expect(restored == row)
        #expect(restored.rawCredits == 0)
        #expect(restored.totals.totalTokens == 451_770_000)
    }

    @Test("new cached summaries preserve reported and unreported credits through a round trip")
    func newCachePreservesCreditPresence() throws {
        let summary = try decode("""
        {"data":[
          {"date":"2026-09-01","totals":{"credits":0}},
          {"date":"2026-09-02","totals":{"text_total_tokens":1000}},
          {"date":"2026-09-03"}
        ]}
        """)
        let restored = try JSONDecoder().decode(
            ApiEquivalentSummary.self,
            from: JSONEncoder().encode(summary))

        #expect(restored == summary)
        #expect(try restored.dailyRows.map(reportedCredits) == [true, false, false])
        #expect(try restored.dailyRows.map(reportedTotals) == [true, true, false])
    }

    private func reportedCredits(_ row: ApiEquivalentDailyRow) throws -> Bool? {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row))
        return (object as? [String: Any])?["creditsReported"] as? Bool
    }

    private func reportedTotals(_ row: ApiEquivalentDailyRow) throws -> Bool? {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row))
        return (object as? [String: Any])?["totalsReported"] as? Bool
    }

    private func decode(_ payload: String) throws -> ApiEquivalentSummary {
        let start = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01T00:00:00Z
        return try ApiEquivalentSummary.decodeAnalytics(
            from: Data(payload.utf8),
            window: DateInterval(start: start, duration: 7 * 86_400),
            calculatedAt: start,
            startDate: "2026-09-01",
            endDate: "2026-09-07")
    }
}
