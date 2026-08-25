import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Usage cost repository — concurrency")
struct UsageCostRepositoryConcurrencyTests {
    @Test("identical concurrent callers share one physical scan")
    func concurrentCallersShareInflightWork() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n",
            basename: "rollout-concurrent.jsonl")
        let gate = RepositoryFlightGate()
        let repository = fixture.repository(beforeFlight: { await gate.wait() })
        let request = fullWindowQuery()

        let tasks = (0..<6).map { _ in
            Task { () throws -> Int in
                let summaries = try await repository.summaries(
                    for: [request], calculatedAt: fixedNow, policy: .force)
                return summaries[request.id]?.totals.totalTokens ?? -1
            }
        }
        var joined = false
        for _ in 0..<1_000 {
            if await repository.diagnosticsSnapshot().sharedFlightHits == 5 {
                joined = true
                break
            }
            await Task.yield()
        }
        await gate.open()
        var tokenCounts: [Int] = []
        for task in tasks { tokenCounts.append(try await task.value) }
        let diagnostics = await repository.diagnosticsSnapshot()

        #expect(joined)
        #expect(tokenCounts.count == 6)
        #expect(tokenCounts.allSatisfy { $0 == 105 })
        #expect(diagnostics.indexPasses == 1)
        #expect(diagnostics.sharedFlightHits == 5)
        #expect(diagnostics.maxConcurrentScans == 1)
    }

    @Test("cancelling one shared waiter does not cancel the physical scan")
    func cancelledJoinerDoesNotCancelSharedWork() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n",
            basename: "rollout-cancelled-joiner.jsonl")
        let gate = RepositoryFlightGate()
        let repository = fixture.repository(beforeFlight: { await gate.wait() })
        let request = fullWindowQuery()
        let owner = Task {
            try await repository.summaries(
                for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        }
        let joiner = Task {
            try await repository.summaries(
                for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        }
        for _ in 0..<1_000 {
            if await repository.diagnosticsSnapshot().sharedFlightHits == 1 { break }
            await Task.yield()
        }
        joiner.cancel()
        await gate.open()

        let ownerResult = try await owner.value
        #expect(ownerResult[request.id]?.totals.totalTokens == 105)
        do {
            _ = try await joiner.value
            Issue.record("Expected cancelled joiner to throw")
        } catch is CancellationError {
            // Expected: cancelling a waiter must not cancel the shared physical task.
        }
        let diagnostics = await repository.diagnosticsSnapshot()
        #expect(diagnostics.indexPasses == 1)
    }

    @Test("cancelling the final waiter cancels the physical task")
    func cancellingOnlyWaiterCancelsPhysicalTask() async throws {
        let fixture = try RepositoryFixture()
        try fixture.write(
            tokenLine(timestamp: "2026-06-29T01:00:00Z", input: 100) + "\n",
            basename: "rollout-cancelled-owner.jsonl")
        let gate = RepositoryFlightGate()
        let repository = fixture.repository(beforeFlight: { await gate.wait() })
        let request = fullWindowQuery()
        let queryTask = Task {
            try await repository.summaries(
                for: [request], calculatedAt: fixedNow, policy: .ifChanged)
        }
        for _ in 0..<1_000 {
            if await gate.waitingCount == 1 { break }
            await Task.yield()
        }

        queryTask.cancel()
        var physicalTaskCancelled = false
        for _ in 0..<1_000 {
            if await repository.diagnosticsSnapshot().cancelledFlights == 1 {
                physicalTaskCancelled = true
                break
            }
            await Task.yield()
        }
        await gate.open()

        do {
            _ = try await queryTask.value
            Issue.record("Expected final waiter cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let diagnostics = await repository.diagnosticsSnapshot()
        #expect(physicalTaskCancelled)
        #expect(diagnostics.cancelledFlights == 1)
        #expect(diagnostics.indexPasses == 0)
    }
}
