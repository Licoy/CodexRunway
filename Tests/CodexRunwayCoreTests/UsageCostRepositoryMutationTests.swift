import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Usage cost repository — source mutations")
struct UsageCostRepositoryMutationTests {
    @Test("truncate and same-size rewrite rebuild without stale events")
    func truncateAndSameSizeRewriteRebuild() async throws {
        let fixture = try RepositoryFixture()
        let truncatedFile = try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n"
                + tokenLine(timestamp: "2026-06-29T02:00:00Z", input: 200) + "\n",
            basename: "rollout-truncate.jsonl")
        let originalRewrite = tokenLine(timestamp: "2026-06-29T03:00:00Z", input: 300) + "\n"
        let rewritten = tokenLine(timestamp: "2026-06-29T03:00:00Z", input: 900) + "\n"
        #expect(originalRewrite.utf8.count == rewritten.utf8.count)
        let rewrittenFile = try fixture.write(originalRewrite, basename: "rollout-rewrite.jsonl")
        let truncatedIdentity = try fileIdentity(truncatedFile)
        let rewrittenIdentity = try fileIdentity(rewrittenFile)
        let repository = fixture.repository()
        let request = fullWindowQuery()
        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let before = await repository.diagnosticsSnapshot()

        try replacePreservingIdentity(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 700) + "\n",
            at: truncatedFile)
        try replacePreservingIdentity(rewritten, at: rewrittenFile)
        #expect(try fileIdentity(truncatedFile) == truncatedIdentity)
        #expect(try fileIdentity(rewrittenFile) == rewrittenIdentity)

        let refreshed = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let after = await repository.diagnosticsSnapshot()

        #expect(refreshed[request.id]?.totals.turns == 0)
        #expect(refreshed[request.id]?.totals.totalTokens == 1_610)
        #expect(after.rebuiltFiles == before.rebuiltFiles + 2)
    }

    @Test("append with a changed checkpoint prefix rebuilds the source")
    func changedPrefixBeforeAppendRebuilds() async throws {
        let fixture = try RepositoryFixture()
        let original = tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n"
        let file = try fixture.write(original, basename: "rollout-prefix-change.jsonl")
        let identity = try fileIdentity(file)
        let repository = fixture.repository()
        let request = fullWindowQuery()
        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let before = await repository.diagnosticsSnapshot()

        let rewrittenAndAppended = tokenLine(
            timestamp: "2026-06-29T01:00:00Z", input: 900) + "\n"
            + tokenLine(timestamp: "2026-06-29T02:00:00Z", input: 200) + "\n"
        try replacePreservingIdentity(rewrittenAndAppended, at: file)
        #expect(try fileIdentity(file) == identity)

        let summary = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let after = await repository.diagnosticsSnapshot()

        #expect(summary[request.id]?.totals.turns == 0)
        #expect(summary[request.id]?.totals.totalTokens == 1_110)
        #expect(after.rebuiltFiles == before.rebuiltFiles + 1)
        #expect(after.appendedFiles == before.appendedFiles)
    }

    @Test("deleting a source file cascades its indexed events")
    func deletionCascadesEvents() async throws {
        let fixture = try RepositoryFixture()
        let file = try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n",
            basename: "rollout-delete.jsonl")
        let repository = fixture.repository()
        let request = fullWindowQuery()
        let initial = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let before = await repository.diagnosticsSnapshot()
        #expect(initial[request.id]?.totals.totalTokens == 105)

        try FileManager.default.removeItem(at: file)
        let deleted = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let after = await repository.diagnosticsSnapshot()

        #expect(deleted[request.id]?.source == .unavailable)
        #expect(deleted[request.id]?.totals == .zero)
        #expect(after.removedFiles == before.removedFiles + 1)
    }

    @Test("parser version mismatch rebuilds the derived index")
    func parserVersionMismatchRebuilds() async throws {
        let fixture = try RepositoryFixture()
        let contents = tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n"
        try fixture.write(contents, basename: "rollout-parser-version.jsonl")
        let request = fullWindowQuery()
        let oldRepository = fixture.repository(parserVersion: 1)
        _ = try await oldRepository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)

        let newRepository = fixture.repository(parserVersion: 2)
        let rebuilt = try await newRepository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let diagnostics = await newRepository.diagnosticsSnapshot()

        #expect(rebuilt[request.id]?.totals.totalTokens == 105)
        #expect(diagnostics.bytesRead == contents.utf8.count)
        #expect(diagnostics.databaseRebuilds == 1)
        #expect(diagnostics.rebuiltFiles == 1)
    }
}
