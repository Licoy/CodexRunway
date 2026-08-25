import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Usage cost turn counting")
struct UsageCostTurnCountingTests {
    @Test("task_complete counts as one turn after many model token_count events")
    func taskCompleteCountsAsOneTurn() throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            [
                #"{"timestamp":"2026-06-29T00:00:00Z","type":"session_meta","payload":{"cwd":"/Users/me/dev/content-server"}}"#,
                #"{"timestamp":"2026-06-29T00:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                tokenLine(timestamp: "2026-06-29T00:01:00Z", input: 1000, cached: 800, output: 50, model: "gpt-5.6-sol"),
                tokenLine(timestamp: "2026-06-29T00:01:10Z", input: 1200, cached: 900, output: 40, model: "gpt-5.6-sol"),
                tokenLine(timestamp: "2026-06-29T00:01:20Z", input: 1400, cached: 1000, output: 30, model: "gpt-5.6-sol"),
                taskCompleteLine(timestamp: "2026-06-29T00:01:30Z"),
            ].joined(separator: "\n") + "\n",
            basename: "rollout-turns.jsonl")

        let summary = try UsageCostScanner(codexHome: fixture.codexHome).scanAPIEquivalent(
            window: fullWindowQuery().window)

        #expect(summary.totals.turns == 1)
        #expect(summary.totals.uncachedInputTokens == 900)
        #expect(summary.totals.cachedInputTokens == 2_700)
        #expect(summary.totals.outputTokens == 120)
        #expect(summary.dailyRows.map(\.totals.turns) == [1])
        #expect(summary.projectRows.map(\.name) == ["content-server"])
        #expect(summary.projectRows.map(\.totals.turns) == [1])
    }

    @Test("token_count events without task_complete do not count as turns")
    func tokenCountsAreModelCallsNotTurns() throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            [
                tokenLine(timestamp: "2026-06-29T00:01:00Z", input: 100),
                tokenLine(timestamp: "2026-06-29T00:02:00Z", input: 200),
            ].joined(separator: "\n") + "\n",
            basename: "rollout-model-calls.jsonl")

        let summary = try UsageCostScanner(codexHome: fixture.codexHome).scanAPIEquivalent(
            window: fullWindowQuery().window)

        #expect(summary.totals.turns == 0)
        #expect(summary.totals.totalTokens == 310)
    }

    @Test("each task_complete is one turn even across subagent files")
    func eachTaskCompleteIsOneTurn() throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            [
                tokenLine(timestamp: "2026-06-29T00:01:00Z", input: 100),
                taskCompleteLine(timestamp: "2026-06-29T00:01:30Z", turnID: "parent"),
            ].joined(separator: "\n") + "\n",
            basename: "rollout-parent.jsonl")
        try fixture.write(
            [
                tokenLine(timestamp: "2026-06-29T00:02:00Z", input: 200),
                taskCompleteLine(timestamp: "2026-06-29T00:02:30Z", turnID: "child"),
            ].joined(separator: "\n") + "\n",
            basename: "rollout-subagent.jsonl")

        let summary = try UsageCostScanner(codexHome: fixture.codexHome).scanAPIEquivalent(
            window: fullWindowQuery().window)

        #expect(summary.totals.turns == 2)
        #expect(summary.totals.totalTokens == 310)
    }

    @Test("indexed summaries use the same task_complete turn rule as the scanner")
    func repositoryMatchesScannerTurnRule() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            [
                tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100),
                tokenLine(timestamp: "2026-06-29T01:01:00Z", input: 200),
                taskCompleteLine(timestamp: "2026-06-29T01:02:00Z"),
                tokenLine(timestamp: "2026-06-29T02:00:00Z", input: 50, model: "unknown-model"),
            ].joined(separator: "\n") + "\n",
            basename: "rollout-indexed-turns.jsonl")
        let request = fullWindowQuery()
        let scanner = try UsageCostScanner(codexHome: fixture.codexHome).scanAPIEquivalent(
            window: request.window,
            calculatedAt: fixedNow)
        let indexed = try #require(try await fixture.repository().summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)[request.id])

        #expect(scanner.totals.turns == 1)
        #expect(indexed.totals == scanner.totals)
        #expect(indexed.dailyRows == scanner.dailyRows)
        #expect(indexed.modelRows == scanner.modelRows)
    }

    @Test("session activity counts task_complete rather than token_count events")
    func sessionActivityCountsTaskComplete() throws {
        let fixture = try RepositoryFixture()
        let sessionID = "019f17a5-436d-73b2-a93d-7af3e78cc829"
        try fixture.write(
            [
                #"{"timestamp":"2026-06-29T00:00:00Z","type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"/Users/me/dev/codex-runway"}}"#,
                tokenLine(timestamp: "2026-06-29T00:01:00Z", input: 1000, cached: 100, output: 50),
                tokenLine(timestamp: "2026-06-29T00:02:00Z", input: 800, cached: 80, output: 20),
                taskCompleteLine(timestamp: "2026-06-29T00:03:00Z"),
            ].joined(separator: "\n") + "\n",
            basename: "rollout-\(sessionID).jsonl")

        let session = try #require(
            try SessionActivityScanner(codexHome: fixture.codexHome).scan(limit: 1).items.first)
        #expect(session.totals.turns == 1)
        #expect(session.totals.totalTokens == 1_870)
    }
}
