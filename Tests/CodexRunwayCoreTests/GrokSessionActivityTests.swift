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
        // Official grok-4.5 API: (600*$2 + 400*$0.30 + 200*$6) + (400*$2 + 100*$0.30 + 100*$6) / 1e6
        // CLI costUsdTicks ($2) must not be used as API-equivalent.
        #expect(result.recentItems[0].totals.estimatedUSD == Decimal(string: "0.00395"))
        #expect(result.totals.totalTokens == 1_800)
        #expect(result.modelRows.first?.model == "grok-4.5-build")
        #expect(result.modelRows.first?.totals.totalTokens == 1_800)
        #expect(result.modelRows.first?.totals.estimatedUSD == Decimal(string: "0.00395"))
        #expect(result.costSummary.isDisplayableCost)
        #expect(result.costSummary.confidence == .priced)
        #expect(result.costSummary.estimatedUSD == Decimal(string: "0.00395"))
        #expect(result.costSummary.pricingVersion == GrokPricingTable.version)
        #expect(result.costSummary.warnings.isEmpty)
        #expect(!result.dailyTokens.isEmpty)
        #expect(result.dailyTokens.values.reduce(0, +) == 1_800)
    }

    @Test("keeps priced API totals when some models are unknown")
    func keepsPricedTotalsWithUnknownModels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-mixed-models-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(
            home: root,
            id: "mixed",
            cwd: "/tmp/mixed",
            model: "grok-4.5",
            updatedAt: "2026-08-01T00:00:00Z",
            updates: """
            {"timestamp":1785541392,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":2000,"outputTokens":100,"totalTokens":2100,"cachedReadTokens":0,"modelUsage":{"grok-4.5-build":{"inputTokens":1000,"outputTokens":50,"totalTokens":1050,"cachedReadTokens":0},"mystery-model":{"inputTokens":1000,"outputTokens":50,"totalTokens":1050,"cachedReadTokens":0}}}}}}
            """)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try GrokSessionScanner(grokHome: root).scan(
            recentLimit: 1,
            sessionLimit: 5,
            costWindow: DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), end: now),
            now: now)

        let priced = GrokPricingTable.cost(
            model: "grok-4.5-build",
            inputTokens: 1_000,
            cachedInputTokens: 0,
            outputTokens: 50)
        #expect(result.costSummary.estimatedUSD == priced)
        #expect(result.costSummary.confidence == .priced)
        #expect(result.costSummary.modelRows.map(\.name) == ["grok-4.5-build", "mystery-model"])
        #expect(result.costSummary.modelRows[0].estimatedUSD == priced)
        #expect(result.costSummary.modelRows[1].estimatedUSD == nil)
        #expect(result.costSummary.warnings == ["unknown-model:mystery-model"])
    }

    @Test("attributes models by day so partial windows stay priced")
    func attributesModelsByDayInPartialWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-window-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calendar = Calendar.autoupdatingCurrent
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))!
        let day3 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 15))!
        let day1Noon = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 15))!
        try writeSession(
            home: root,
            id: "span",
            cwd: "/tmp/span",
            model: "grok-4.5",
            updatedAt: "2026-08-03T00:00:00Z",
            updates: """
            {"timestamp":\(Int(day1Noon.timeIntervalSince1970)),"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":1000,"outputTokens":0,"totalTokens":1000,"cachedReadTokens":0,"modelUsage":{"grok-4.5-build":{"inputTokens":1000,"outputTokens":0,"totalTokens":1000,"cachedReadTokens":0}}}}}}
            {"timestamp":\(Int(day3.timeIntervalSince1970)),"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":2000,"outputTokens":0,"totalTokens":2000,"cachedReadTokens":0,"modelUsage":{"grok-4.6-build":{"inputTokens":2000,"outputTokens":0,"totalTokens":2000,"cachedReadTokens":0}}}}}}
            """)
        let result = try GrokSessionScanner(grokHome: root).scan(
            recentLimit: 0,
            sessionLimit: 5,
            costWindow: DateInterval(start: day1, end: day2),
            now: day2)

        #expect(result.costSummary.modelRows.map(\.name) == ["grok-4.5-build"])
        #expect(result.costSummary.modelRows.contains { $0.name == "grok" } == false)
        #expect(result.costSummary.estimatedUSD == Decimal(string: "0.002"))
        #expect(result.totals.totalTokens == 1_000)
    }

    @Test("prices long-context turns at the published 200k threshold")
    func pricesLongContextTurns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-longctx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(
            home: root,
            id: "long",
            cwd: "/tmp/long",
            model: "grok-4.5",
            updatedAt: "2026-08-01T00:00:00Z",
            updates: """
            {"timestamp":1785541392,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":200000,"outputTokens":0,"totalTokens":200000,"cachedReadTokens":0,"modelUsage":{"grok-4.5":{"inputTokens":200000,"outputTokens":0,"totalTokens":200000,"cachedReadTokens":0}}}}}}
            """)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try GrokSessionScanner(grokHome: root).scan(
            recentLimit: 0,
            sessionLimit: 5,
            costWindow: DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), end: now),
            now: now)

        #expect(result.costSummary.estimatedUSD == Decimal(string: "0.8"))
    }

    private func writeSession(
        home: URL,
        id: String,
        cwd: String,
        model: String,
        updatedAt: String,
        updates: String
    ) throws {
        let sessionDir = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("%2Ftmp", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let summary = """
        {
          "info": {"id": "\(id)", "cwd": "\(cwd)"},
          "generated_title": "\(id)",
          "updated_at": "\(updatedAt)",
          "last_active_at": "\(updatedAt)",
          "num_chat_messages": 1,
          "current_model_id": "\(model)"
        }
        """
        try Data(summary.utf8).write(to: sessionDir.appendingPathComponent("summary.json"))
        try Data(updates.utf8).write(to: sessionDir.appendingPathComponent("updates.jsonl"))
    }
}
