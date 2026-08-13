import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Usage cost repository — aggregation")
struct UsageCostRepositoryAggregationTests {
    @Test("repository aggregation matches the streaming scanner field by field")
    func repositoryMatchesStreamingScanner() async throws {
        let fixture = try RepositoryFixture()
        let contents = """
        {"timestamp":"2026-06-28T23:58:00Z","type":"session_meta","payload":{"cwd":"/Users/me/dev/codex-runway"}}
        {"timestamp":"2026-06-28T23:59:00Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-29T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":5,"reasoning_output_tokens":2}}}}
        {"timestamp":"2026-06-29T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":3}}},"turn_context":{"model":"unknown-model"}}
        """
        try fixture.write(contents, basename: "rollout-differential.jsonl")
        let request = fullWindowQuery()
        let scanner = try UsageCostScanner(codexHome: fixture.codexHome).scanAPIEquivalent(
            window: request.window,
            calculatedAt: fixedNow)
        let indexed = try #require(try await fixture.repository().summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)[request.id])

        #expect(indexed.source == scanner.source)
        #expect(indexed.confidence == scanner.confidence)
        #expect(indexed.totals == scanner.totals)
        #expect(indexed.dailyRows == scanner.dailyRows)
        #expect(indexed.modelRows == scanner.modelRows)
        #expect(indexed.projectRows == scanner.projectRows)
        #expect(indexed.estimatedUSD == scanner.estimatedUSD)
        #expect(indexed.warnings == scanner.warnings)
        #expect(indexed.pricingVersion == scanner.pricingVersion)
    }

    @Test("cold batch scan includes both DateInterval endpoints once")
    func coldBatchScanIncludesEndpoints() async throws {
        let fixture = try RepositoryFixture()
        let contents = [
            tokenLine(timestamp: "2026-06-29T00:00:00Z", input: 100),
            tokenLine(timestamp: "2026-06-29T12:00:00Z", input: 200),
            tokenLine(timestamp: "2026-06-30T00:00:00Z", input: 300),
        ].joined(separator: "\n") + "\n"
        try fixture.write(contents, basename: "rollout-batch.jsonl")
        let repository = fixture.repository()
        let firstHalf = query(
            id: "first",
            start: "2026-06-29T00:00:00Z",
            end: "2026-06-29T12:00:00Z")
        let wholeDay = query(
            id: "whole",
            start: "2026-06-29T00:00:00Z",
            end: "2026-06-30T00:00:00Z")

        let summaries = try await repository.summaries(
            for: [firstHalf, wholeDay],
            calculatedAt: fixedNow,
            policy: .ifChanged)
        let diagnostics = await repository.diagnosticsSnapshot()

        #expect(summaries["first"]?.totals.turns == 2)
        #expect(summaries["first"]?.totals.totalTokens == 310)
        #expect(summaries["whole"]?.totals.turns == 3)
        #expect(summaries["whole"]?.totals.totalTokens == 615)
        #expect(summaries["whole"]?.calculatedAt == fixedNow)
        #expect(diagnostics.bytesRead == contents.utf8.count)
        #expect(diagnostics.rebuiltFiles == 1)
        #expect(diagnostics.indexPasses == 1)
    }

    @Test("timestamps group by the configured local calendar day")
    func timestampsUseLocalCalendarGrouping() async throws {
        let fixture = try RepositoryFixture()
        let contents = [
            tokenLine(timestamp: "2026-06-29T18:00:00.125Z", input: 100),
            tokenLine(timestamp: "2026-06-29T23:30:00-02:00", input: 200),
        ].joined(separator: "\n") + "\n"
        try fixture.write(contents, basename: "rollout-local-days.jsonl")
        let request = query(
            id: "local",
            start: "2026-06-29T17:00:00Z",
            end: "2026-06-30T02:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!

        let summary = try #require(try await fixture.repository(calendar: calendar).summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)[request.id])

        #expect(summary.totals.turns == 2)
        #expect(summary.dailyRows.map(\.date) == ["2026-06-30"])
        #expect(summary.dailyRows.map(\.totals.totalTokens) == [310])
    }

    @Test("local day keys remain Gregorian when the system uses another calendar")
    func localDayKeysRemainGregorian() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T18:00:00Z", input: 100) + "\n",
            basename: "rollout-buddhist-calendar.jsonl")
        let request = query(
            id: "local-gregorian-key",
            start: "2026-06-29T17:00:00Z",
            end: "2026-06-29T19:00:00Z")
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!

        let summary = try #require(try await fixture.repository(calendar: calendar).summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)[request.id])

        #expect(summary.dailyRows.map(\.date) == ["2026-06-30"])
    }

    @Test("changing the aggregation time zone rebuilds the derived index")
    func timeZoneChangeRebuildsIndex() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T18:00:00Z", input: 100) + "\n",
            basename: "rollout-time-zone-change.jsonl")
        let request = query(
            id: "time-zone",
            start: "2026-06-29T17:00:00Z",
            end: "2026-06-29T19:00:00Z")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcRepository = fixture.repository(calendar: utc)
        let utcSummary = try #require(try await utcRepository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)[request.id])
        #expect(utcSummary.dailyRows.map(\.date) == ["2026-06-29"])

        var singapore = Calendar(identifier: .gregorian)
        singapore.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let localRepository = fixture.repository(calendar: singapore)
        let localSummary = try #require(try await localRepository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)[request.id])
        let diagnostics = await localRepository.diagnosticsSnapshot()

        #expect(localSummary.dailyRows.map(\.date) == ["2026-06-30"])
        #expect(diagnostics.databaseRebuilds == 1)
    }

    @Test("invalid token counts are reported and skipped")
    func invalidTokenCountsAreReported() async throws {
        let fixture = try RepositoryFixture()
        let overflow = """
        {"timestamp":"2026-06-29T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":\(Int.max),"reasoning_output_tokens":1}}}}
        """
        try fixture.write(
            [
                tokenLine(timestamp: "2026-06-29T01:00:00Z", input: Int.min),
                overflow,
                tokenLine(timestamp: "2026-06-29T02:00:00Z", input: 100),
            ].joined(separator: "\n") + "\n",
            basename: "rollout-invalid-token-counts.jsonl")
        let repository = fixture.repository()
        let request = fullWindowQuery()

        let summary = try #require(try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)[request.id])
        let diagnostics = await repository.diagnosticsSnapshot()

        #expect(summary.totals.turns == 1)
        #expect(summary.totals.totalTokens == 105)
        #expect(summary.warnings.contains("malformed-jsonl-lines:2"))
        #expect(diagnostics.malformedCandidateLines == 2)
    }

    @Test("cross-record token overflow throws instead of trapping")
    func crossRecordOverflowThrows() async throws {
        let fixture = try RepositoryFixture()
        let contents = [
            tokenLine(
                timestamp: "2026-06-29T01:00:00Z",
                input: Int.max,
                output: 0,
                model: "gpt-5.5"),
            tokenLine(
                timestamp: "2026-06-29T02:00:00Z",
                input: 1,
                output: 0,
                model: "unknown-model"),
        ].joined(separator: "\n") + "\n"
        try fixture.write(contents, basename: "rollout-aggregate-overflow.jsonl")
        let request = fullWindowQuery()

        #expect(throws: UsageCostArithmeticError.self) {
            _ = try UsageCostScanner(codexHome: fixture.codexHome).scanAPIEquivalent(
                window: request.window,
                calculatedAt: fixedNow)
        }
        do {
            _ = try await fixture.repository().summaries(
                for: [request], calculatedAt: fixedNow, policy: .ifChanged)
            Issue.record("Expected repository aggregation overflow")
        } catch is UsageCostArithmeticError {
            // Expected.
        }
    }

    @Test("duplicate query identifiers fail instead of overwriting a result")
    func duplicateQueryIdentifiersFail() async throws {
        let fixture = try RepositoryFixture()
        let repository = fixture.repository()
        let duplicate = fullWindowQuery()

        do {
            _ = try await repository.summaries(
                for: [duplicate, duplicate],
                calculatedAt: fixedNow,
                policy: .ifChanged)
            Issue.record("Expected duplicate query identifier failure")
        } catch UsageCostRepositoryError.duplicateQueryID(let identifier) {
            #expect(identifier == duplicate.id)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("non-finite query windows fail explicitly")
    func nonFiniteQueryWindowFails() async throws {
        let fixture = try RepositoryFixture()
        let invalid = ApiCostQuery(
            id: "invalid-window",
            window: DateInterval(
                start: Date(timeIntervalSince1970: .nan),
                end: fixedNow))

        do {
            _ = try await fixture.repository().summaries(
                for: [invalid],
                calculatedAt: fixedNow,
                policy: .ifChanged)
            Issue.record("Expected invalid query window failure")
        } catch UsageCostRepositoryError.invalidQueryWindow(let identifier) {
            #expect(identifier == invalid.id)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("pricing version change reprices indexed tokens without source IO")
    func pricingVersionChangeDoesNotReadSources() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 1_000_000, output: 1_000_000) + "\n",
            basename: "rollout-pricing.jsonl")
        let request = fullWindowQuery()
        let cheapRepository = fixture.repository(
            priceBook: priceBook(version: "cheap", input: 1, cached: 1, output: 1))
        let cheap = try await cheapRepository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)

        let expensiveRepository = fixture.repository(
            priceBook: priceBook(version: "expensive", input: 10, cached: 10, output: 10))
        let expensive = try await expensiveRepository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let diagnostics = await expensiveRepository.diagnosticsSnapshot()

        #expect(cheap[request.id]?.pricingVersion == "cheap")
        #expect(expensive[request.id]?.pricingVersion == "expensive")
        #expect(cheap[request.id]?.estimatedUSD == 2)
        #expect(expensive[request.id]?.estimatedUSD == 20)
        #expect(diagnostics.bytesRead == 0)
        #expect(diagnostics.rebuiltFiles == 0)
    }

    @Test("project cost sums each model price instead of using one equivalent rate")
    func projectCostIsModelAware() async throws {
        let fixture = try RepositoryFixture()
        let contents = """
        {"timestamp":"2026-06-29T00:00:00Z","type":"session_meta","payload":{"cwd":"/Users/me/dev/codex-runway"}}
        \(tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 1_000_000, output: 0, model: "gpt-5.6-sol"))
        \(tokenLine(timestamp: "2026-06-29T02:00:00Z", input: 1_000_000, output: 0, model: "gpt-5.6-luna"))
        """
        try fixture.write(contents, basename: "rollout-project-models.jsonl")
        let prices = [
            "gpt-5.6-sol": PricingTable.Price(
                inputPerMillion: 5,
                cachedInputPerMillion: 0.5,
                outputPerMillion: 30),
            "gpt-5.6-luna": PricingTable.Price(
                inputPerMillion: 0.2,
                cachedInputPerMillion: 0.02,
                outputPerMillion: 1.2),
        ]
        let priceBook = UsageCostPriceBook(
            version: "model-aware",
            priceForModel: { prices[$0] },
            equivalentPrice: PricingTable.Price(
                inputPerMillion: 999,
                cachedInputPerMillion: 999,
                outputPerMillion: 999))

        let summary = try #require(try await fixture.repository(priceBook: priceBook).summaries(
            for: [fullWindowQuery()], calculatedAt: fixedNow, policy: .ifChanged)["full"])

        #expect(summary.projectRows.count == 1)
        #expect(summary.projectRows[0].name == "codex-runway")
        #expect(summary.projectRows[0].estimatedUSD == 5.2)
        #expect(summary.estimatedUSD == 5.2)
    }

    @Test("spark usage keeps the window priced instead of falling back to tokens-only")
    func sparkAndSolWindowStaysPriced() async throws {
        let fixture = try RepositoryFixture()
        let contents = """
        {"timestamp":"2026-06-29T00:00:00Z","type":"session_meta","payload":{"cwd":"/Users/me/dev/codex-runway"}}
        \(tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 1_000_000, output: 0, model: "gpt-5.6-sol"))
        \(tokenLine(timestamp: "2026-06-29T02:00:00Z", input: 1_000_000, output: 0, model: "gpt-5.3-codex-spark"))
        """
        try fixture.write(contents, basename: "rollout-spark-models.jsonl")

        let summary = try #require(try await fixture.repository().summaries(
            for: [fullWindowQuery()], calculatedAt: fixedNow, policy: .ifChanged)["full"])

        #expect(summary.confidence == .priced)
        #expect(summary.estimatedUSD == 6.75)
        #expect(summary.modelRows.first { $0.name == "gpt-5.3-codex-spark" }?.estimatedUSD == 1.75)
    }
}
