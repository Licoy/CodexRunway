import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Usage cost repository — incremental reads")
struct UsageCostRepositoryIncrementalTests {
    @Test("warm query reads no source bytes and append reads only the suffix")
    func warmAndAppendAreIncremental() async throws {
        let fixture = try RepositoryFixture()
        let initial = tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n"
        let file = try fixture.write(initial, basename: "rollout-append.jsonl")
        let repository = fixture.repository()
        let request = fullWindowQuery()

        let cold = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let afterCold = await repository.diagnosticsSnapshot()
        let warm = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let afterWarm = await repository.diagnosticsSnapshot()

        #expect(cold[request.id]?.totals.totalTokens == 105)
        #expect(cold[request.id]?.totals.turns == 0)
        #expect(warm[request.id] == cold[request.id])
        #expect(afterWarm.bytesRead == afterCold.bytesRead)
        #expect(afterWarm.validationBytesRead == afterCold.validationBytesRead)
        #expect(afterWarm.cacheHits > afterCold.cacheHits)

        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .force)
        let afterForce = await repository.diagnosticsSnapshot()
        #expect(afterForce.bytesRead == afterWarm.bytesRead)
        #expect(afterForce.validationBytesRead == afterWarm.validationBytesRead)

        let suffix = tokenLine(timestamp: "2026-06-29T02:00:00Z", input: 200) + "\n"
        try append(suffix, to: file)
        let appended = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let afterAppend = await repository.diagnosticsSnapshot()

        #expect(appended[request.id]?.totals.turns == 0)
        #expect(appended[request.id]?.totals.totalTokens == 310)
        #expect(afterAppend.bytesRead - afterForce.bytesRead == suffix.utf8.count)
        #expect(afterAppend.appendedFiles == afterForce.appendedFiles + 1)

        let largeSuffix = String(repeating: "x", count: 1_024 * 1_024 - 1) + "\n"
        try append(largeSuffix, to: file)
        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let afterLargeAppend = await repository.diagnosticsSnapshot()
        let physicalReadDelta = afterLargeAppend.bytesRead + afterLargeAppend.validationBytesRead
            - afterAppend.bytesRead - afterAppend.validationBytesRead

        #expect(physicalReadDelta <= largeSuffix.utf8.count + 4 * Int(UsageCostSourceIndexer.hashWindowBytes))
        #expect(physicalReadDelta < 1_024 * 1_024 * 11 / 10)
    }

    @Test("first-block validation expands as a short source grows")
    func shortSourceExpandsFirstHashWindow() async throws {
        let fixture = try RepositoryFixture()
        let initial = tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n"
        let file = try fixture.write(initial, basename: "rollout-growing-prefix.jsonl")
        let repository = fixture.repository()
        let request = fullWindowQuery()
        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)

        let padding = String(repeating: "x", count: 2 * Int(UsageCostSourceIndexer.hashWindowBytes)) + "\n"
        try append(padding, to: file)
        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let expanded = try UsageCostIndexStore(
            url: fixture.databaseURL,
            parserVersion: 1,
            timeZoneIdentifier: utcCalendar().timeZone.identifier)
        let source = try #require(expanded.sourceRows().first)
        #expect(source.firstHashLength == Int(UsageCostSourceIndexer.hashWindowBytes))
        let beforeRewrite = await repository.diagnosticsSnapshot()

        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data("y".utf8))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("z\n".utf8))
        try handle.synchronize()
        try handle.close()
        _ = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let afterRewrite = await repository.diagnosticsSnapshot()

        #expect(afterRewrite.rebuiltFiles == beforeRewrite.rebuiltFiles + 1)
        #expect(afterRewrite.appendedFiles == beforeRewrite.appendedFiles)
    }

    @Test("an unterminated tail is visible but checkpointed only after LF")
    func unterminatedTailIsRereadWithoutDuplication() async throws {
        let fixture = try RepositoryFixture()
        let tail = tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100)
        let file = try fixture.write(tail, basename: "rollout-tail.jsonl")
        let repository = fixture.repository()
        let request = fullWindowQuery()

        let first = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let firstDiagnostics = await repository.diagnosticsSnapshot()
        let second = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let secondDiagnostics = await repository.diagnosticsSnapshot()

        #expect(first[request.id]?.totals.totalTokens == 105)
        #expect(second[request.id]?.totals.totalTokens == 105)
        #expect(first[request.id]?.totals.turns == 0)
        #expect(secondDiagnostics.bytesRead - firstDiagnostics.bytesRead == tail.utf8.count)
        #expect(secondDiagnostics.incompleteTailFiles > firstDiagnostics.incompleteTailFiles)

        try append("\n", to: file)
        let completed = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let completedDiagnostics = await repository.diagnosticsSnapshot()
        let warm = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let warmDiagnostics = await repository.diagnosticsSnapshot()

        #expect(completed[request.id]?.totals.totalTokens == 105)
        #expect(warm[request.id]?.totals.totalTokens == 105)
        #expect(completedDiagnostics.bytesRead - secondDiagnostics.bytesRead == tail.utf8.count + 1)
        #expect(warmDiagnostics.bytesRead == completedDiagnostics.bytesRead)
    }

    @Test("an unterminated malformed line is warned once per result")
    func provisionalMalformedTailDoesNotAccumulate() async throws {
        let fixture = try RepositoryFixture()
        let tail = #"{"type":"token_count""#
        let file = try fixture.write(tail, basename: "rollout-malformed-tail.jsonl")
        let repository = fixture.repository()
        let request = fullWindowQuery()

        let first = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let second = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)

        #expect(first[request.id]?.warnings.contains("malformed-jsonl-lines:1") == true)
        #expect(second[request.id]?.warnings.contains("malformed-jsonl-lines:1") == true)
        #expect(second[request.id]?.warnings.contains("malformed-jsonl-lines:2") == false)

        try append("\n", to: file)
        let completed = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        let warm = try await repository.summaries(
            for: [request], calculatedAt: fixedNow, policy: .ifChanged)

        #expect(completed[request.id]?.warnings.contains("malformed-jsonl-lines:1") == true)
        #expect(warm[request.id]?.warnings.contains("malformed-jsonl-lines:1") == true)
        #expect(warm[request.id]?.warnings.contains("malformed-jsonl-lines:2") == false)
    }
}
