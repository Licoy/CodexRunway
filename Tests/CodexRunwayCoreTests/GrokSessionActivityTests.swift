import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok session activity")
struct GrokSessionActivityTests {
    @Test("converts costUsdTicks to USD")
    func costTicksToUSD() {
        #expect(GrokSessionScanner.usd(fromCostTicks: 2_486_936_000) == Decimal(string: "2.486936"))
        #expect(GrokSessionScanner.usd(fromCostTicks: 0) == nil)
        #expect(GrokSessionScanner.usd(fromCostTicks: nil) == nil)
    }

    @Test("scans summary and turn_completed usage")
    func scansSummaryAndUsage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-session-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionDir = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("%2Ftmp", isDirectory: true)
            .appendingPathComponent("session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = """
        {
          "info": {"id": "session-1", "cwd": "/tmp/demo-project"},
          "generated_title": "Demo session",
          "updated_at": "2026-08-01T00:00:00Z",
          "last_active_at": "2026-08-01T01:00:00Z",
          "num_chat_messages": 4,
          "current_model_id": "grok-4.5"
        }
        """
        try Data(summary.utf8).write(to: sessionDir.appendingPathComponent("summary.json"))

        let updates = """
        {"timestamp":1785541389,"params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}
        {"timestamp":1785541392,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":1000,"outputTokens":200,"totalTokens":1200,"cachedReadTokens":400,"reasoningTokens":50,"modelCalls":2,"costUsdTicks":1500000000,"modelUsage":{"grok-4.5-build":{"inputTokens":1000,"outputTokens":200,"totalTokens":1200,"cachedReadTokens":400,"reasoningTokens":50,"modelCalls":2,"costUsdTicks":1500000000}}}}}}
        {"timestamp":1785541492,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":500,"outputTokens":100,"totalTokens":600,"cachedReadTokens":100,"reasoningTokens":10,"modelCalls":1,"costUsdTicks":500000000,"modelUsage":{"grok-4.5-build":{"inputTokens":500,"outputTokens":100,"totalTokens":600,"cachedReadTokens":100,"reasoningTokens":10,"modelCalls":1,"costUsdTicks":500000000}}}}}}
        """
        try Data(updates.utf8).write(to: sessionDir.appendingPathComponent("updates.jsonl"))

        let summary2Dir = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("%2Ftmp", isDirectory: true)
            .appendingPathComponent("session-2", isDirectory: true)
        try FileManager.default.createDirectory(at: summary2Dir, withIntermediateDirectories: true)
        let older = """
        {
          "info": {"id": "session-2", "cwd": "/tmp/other"},
          "session_summary": "Older",
          "updated_at": "2026-07-01T00:00:00Z",
          "num_chat_messages": 1,
          "current_model_id": "grok-4.5"
        }
        """
        try Data(older.utf8).write(to: summary2Dir.appendingPathComponent("summary.json"))
        // Touch mtimes so session-1 is newer.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_100)],
            ofItemAtPath: sessionDir.appendingPathComponent("summary.json").path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: summary2Dir.appendingPathComponent("summary.json").path)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yearStart = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let result = try GrokSessionScanner(grokHome: root).scan(
            recentLimit: 5,
            sessionLimit: 10,
            costWindow: DateInterval(start: yearStart, end: now),
            now: now)

        #expect(result.recentItems.count == 2)
        #expect(result.recentItems[0].id == "session-1")
        #expect(result.recentItems[0].title == "Demo session")
        #expect(result.recentItems[0].projectName == "demo-project")
        #expect(result.recentItems[0].totals.totalTokens == 1_800)
        #expect(result.recentItems[0].totals.turns == 2)
        #expect(result.recentItems[0].totals.estimatedUSD == Decimal(string: "2"))
        #expect(result.totals.totalTokens == 1_800)
        #expect(result.modelRows.first?.model == "grok-4.5-build")
        #expect(result.modelRows.first?.totals.totalTokens == 1_800)
        #expect(result.costSummary.isDisplayableCost)
        #expect(result.costSummary.estimatedUSD == Decimal(string: "2"))
        #expect(!result.dailyTokens.isEmpty)
        #expect(result.dailyTokens.values.reduce(0, +) == 1_800)
    }
}
