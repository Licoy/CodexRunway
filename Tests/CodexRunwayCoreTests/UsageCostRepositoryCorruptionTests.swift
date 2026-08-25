import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Usage cost repository — database recovery")
struct UsageCostRepositoryCorruptionTests {
    @Test("a corrupt derived database is rebuilt from source logs")
    func corruptDatabaseIsRebuilt() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n",
            basename: "rollout-corrupt-db.jsonl")
        try Data("not-a-sqlite-database".utf8).write(to: fixture.databaseURL)
        let repository = fixture.repository()

        let summaries = try await repository.summaries(
            for: [fullWindowQuery()], calculatedAt: fixedNow, policy: .ifChanged)
        let diagnostics = await repository.diagnosticsSnapshot()

        #expect(summaries["full"]?.totals.totalTokens == 105)
        #expect(diagnostics.databaseRebuilds == 1)
        #expect(diagnostics.rebuiltFiles == 1)
    }

    @Test("corruption detected after opening the store rebuilds once")
    func runtimeDatabaseCorruptionIsRebuilt() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n",
            basename: "rollout-runtime-corrupt.jsonl")
        let repository = fixture.repository()
        let request = fullWindowQuery()
        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let before = await repository.diagnosticsSnapshot()
        let external = try SQLiteDatabase(url: fixture.databaseURL)
        try external.execute("DROP TABLE usage_events", operation: "test schema corruption")

        let rebuilt = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let after = await repository.diagnosticsSnapshot()

        #expect(rebuilt[request.id]?.totals.totalTokens == 105)
        #expect(after.databaseRebuilds == before.databaseRebuilds + 1)
        #expect(after.rebuiltFiles == before.rebuiltFiles + 1)
    }

    @Test("wrong SQLite storage classes rebuild the derived index")
    func invalidSQLiteStorageClassIsRebuilt() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n",
            basename: "rollout-storage-class.jsonl")
        let repository = fixture.repository()
        let request = fullWindowQuery()
        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let before = await repository.diagnosticsSnapshot()
        do {
            let external = try SQLiteDatabase(url: fixture.databaseURL)
            try external.execute(
                "UPDATE source_files SET device = 'not-an-integer'",
                operation: "test storage-class corruption")
        }

        let rebuilt = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let after = await repository.diagnosticsSnapshot()

        #expect(rebuilt[request.id]?.totals.totalTokens == 105)
        #expect(after.databaseRebuilds == before.databaseRebuilds + 1)

        do {
            let external = try SQLiteDatabase(url: fixture.databaseURL)
            try external.execute(
                "UPDATE usage_events SET uncached_input_tokens = 'not-an-integer'",
                operation: "test event storage-class corruption")
        }
        let rebuiltEvents = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let final = await repository.diagnosticsSnapshot()
        #expect(rebuiltEvents[request.id]?.totals.totalTokens == 105)
        #expect(final.databaseRebuilds == after.databaseRebuilds + 1)

        do {
            let external = try SQLiteDatabase(url: fixture.databaseURL)
            try external.execute(
                "UPDATE usage_events SET timestamp = 'not-a-number'",
                operation: "test timestamp storage-class corruption")
        }
        let rebuiltTimestamp = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let afterTimestamp = await repository.diagnosticsSnapshot()
        #expect(rebuiltTimestamp[request.id]?.totals.totalTokens == 105)
        #expect(afterTimestamp.databaseRebuilds == final.databaseRebuilds + 1)

        do {
            let external = try SQLiteDatabase(url: fixture.databaseURL)
            try external.execute(
                "UPDATE usage_events SET timestamp = 1e999",
                operation: "test non-finite timestamp corruption")
        }
        let rebuiltInfiniteTimestamp = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let afterInfiniteTimestamp = await repository.diagnosticsSnapshot()
        #expect(rebuiltInfiniteTimestamp[request.id]?.totals.totalTokens == 105)
        #expect(afterInfiniteTimestamp.databaseRebuilds == afterTimestamp.databaseRebuilds + 1)
    }

    @Test("invalid source anomaly counts and fingerprints rebuild the index")
    func invalidSourceMetadataIsRebuilt() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n",
            basename: "rollout-source-corrupt.jsonl")
        let repository = fixture.repository()
        let request = fullWindowQuery()
        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let before = await repository.diagnosticsSnapshot()

        do {
            let external = try SQLiteDatabase(url: fixture.databaseURL)
            try external.execute(
                "UPDATE source_files SET malformed_lines = 9223372036854775807",
                operation: "test source anomaly corruption")
        }
        let rebuiltCounts = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let afterCounts = await repository.diagnosticsSnapshot()
        #expect(rebuiltCounts[request.id]?.totals.totalTokens == 105)
        #expect(afterCounts.databaseRebuilds == before.databaseRebuilds + 1)

        do {
            let external = try SQLiteDatabase(url: fixture.databaseURL)
            try external.execute(
                "UPDATE source_files SET full_hash = NULL",
                operation: "test source fingerprint corruption")
        }
        let rebuiltFingerprint = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let afterFingerprint = await repository.diagnosticsSnapshot()
        #expect(rebuiltFingerprint[request.id]?.totals.totalTokens == 105)
        #expect(afterFingerprint.databaseRebuilds == afterCounts.databaseRebuilds + 1)
    }

    @Test("ordinary SQLite query errors propagate without deleting the index")
    func ordinarySQLiteErrorDoesNotTriggerRebuild() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n",
            basename: "rollout-query-error.jsonl")
        let repository = fixture.repository()
        let request = fullWindowQuery()
        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let before = await repository.diagnosticsSnapshot()
        do {
            let external = try SQLiteDatabase(url: fixture.databaseURL)
            try external.execute(
                "UPDATE usage_events SET uncached_input_tokens = 9223372036854775807",
                operation: "prepare aggregate overflow")
            try external.execute(
                """
                INSERT INTO usage_events
                    (file_id, byte_offset, timestamp, day_key, model, project,
                     uncached_input_tokens, cached_input_tokens, output_tokens, turns)
                SELECT file_id, byte_offset + 1, timestamp, day_key, model, project,
                       9223372036854775807, 0, 0, 0
                FROM usage_events LIMIT 1
                """,
                operation: "create aggregate overflow")
        }

        do {
            _ = try await repository.summaries(
                for: [request], calculatedAt: fixedNow, policy: .ifChanged)
            Issue.record("Expected SQLite aggregate overflow")
        } catch let error as SQLiteError {
            #expect(error.code == 1)
        }
        let after = await repository.diagnosticsSnapshot()

        #expect(after.databaseRebuilds == before.databaseRebuilds)
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }
}
