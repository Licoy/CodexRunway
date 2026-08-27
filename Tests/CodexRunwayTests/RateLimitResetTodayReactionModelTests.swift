import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Rate limit reset today reaction model")
@MainActor
struct RateLimitResetTodayReactionModelTests {
    @Test("panel visibility starts a fetch and hiding stops further polls")
    func pollingFollowsPanelVisibility() async throws {
        let counter = CallCounter()
        let snapshot = RateLimitResetTodayReactionSnapshot.devMock(kind: .no, count: 20)
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: {
                await counter.increment()
                return snapshot
            },
            click: {
                RateLimitResetTodayReactionPostResult(ok: true, data: snapshot)
            })

        model.setRateLimitResetTodayReactionPollingEnabled(true)
        try await waitUntil { await counter.value >= 1 }
        // Immediate fetch on open, then wait pollMs (5s in the fixture) before
        // the next hit. A short pause must not produce a second request.
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(await counter.value == 1)

        model.setRateLimitResetTodayReactionPollingEnabled(false)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await counter.value == 1)
        #expect(model.rateLimitResetTodayReaction?.count == 20)
        #expect(model.rateLimitResetTodayReactionDelta.amount == 0)
        #expect(!model.isRateLimitResetTodayReactionLoading)
    }

    @Test("opening the panel stays in loading until the first fetch finishes")
    func openingShowsLoadingUntilFetch() async throws {
        let fetchStarted = CallCounter()
        let gate = Gate()
        let snapshot = RateLimitResetTodayReactionSnapshot.devMock(kind: .no, count: 20)
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: {
                await fetchStarted.increment()
                await gate.wait()
                return snapshot
            },
            click: {
                RateLimitResetTodayReactionPostResult(ok: true, data: snapshot)
            })

        defer { Task { await gate.open() } }
        model.setRateLimitResetTodayReactionPollingEnabled(true)
        try await waitUntil { await fetchStarted.value >= 1 }
        #expect(model.isRateLimitResetTodayReactionLoading)
        #expect(!model.isRateLimitResetTodayReactionFresh)
        #expect(model.rateLimitResetTodayReaction == nil)
        await gate.open()
        try await waitUntil { !model.isRateLimitResetTodayReactionLoading }
        #expect(model.isRateLimitResetTodayReactionFresh)
        #expect(model.rateLimitResetTodayReaction?.count == 20)
        model.setRateLimitResetTodayReactionPollingEnabled(false)
    }

    @Test("reopening does not float a catch-up delta from a stale count")
    func reopenDoesNotAnnounceCatchUpDelta() async throws {
        let counts = CountBox([10, 50])
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: {
                let count = await counts.next()
                return reactionSnapshot(count: count)
            },
            click: {
                RateLimitResetTodayReactionPostResult(ok: false)
            })

        model.setRateLimitResetTodayReactionPollingEnabled(true)
        try await waitUntil { model.rateLimitResetTodayReaction?.count == 10 }
        #expect(model.rateLimitResetTodayReactionDelta.amount == 0)
        model.setRateLimitResetTodayReactionPollingEnabled(false)

        model.setRateLimitResetTodayReactionPollingEnabled(true)
        #expect(model.isRateLimitResetTodayReactionLoading)
        try await waitUntil { model.rateLimitResetTodayReaction?.count == 50 }
        #expect(!model.isRateLimitResetTodayReactionLoading)
        #expect(model.rateLimitResetTodayReactionDelta.amount == 0)
        model.setRateLimitResetTodayReactionPollingEnabled(false)
    }

    @Test("live poll after a fresh snapshot floats the live increase")
    func livePollAnnouncesIncrease() async throws {
        let counts = CountBox([10, 13])
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: {
                let count = await counts.next()
                return reactionSnapshot(count: count, pollMs: 1_000)
            },
            click: {
                RateLimitResetTodayReactionPostResult(ok: false)
            })

        model.setRateLimitResetTodayReactionPollingEnabled(true)
        try await waitUntil { model.rateLimitResetTodayReaction?.count == 10 }
        #expect(model.rateLimitResetTodayReactionDelta.amount == 0)
        try await waitUntil(attempts: 200) { model.rateLimitResetTodayReaction?.count == 13 }
        #expect(model.rateLimitResetTodayReactionDelta.amount == 3)
        model.setRateLimitResetTodayReactionPollingEnabled(false)
    }

    @Test("click is ignored while the first fetch of a session is in flight")
    func clickIgnoredWhileLoading() async throws {
        let fetches = CallCounter()
        let clicks = CallCounter()
        let gate = Gate()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: {
                let n = await fetches.increment()
                if n == 1 {
                    return reactionSnapshot(count: 10)
                }
                await gate.wait()
                return reactionSnapshot(count: 50)
            },
            click: {
                await clicks.increment()
                return RateLimitResetTodayReactionPostResult(
                    ok: true,
                    data: reactionSnapshot(count: 11))
            })

        defer { Task { await gate.open() } }
        model.setRateLimitResetTodayReactionPollingEnabled(true)
        try await waitUntil { model.rateLimitResetTodayReaction?.count == 10 }
        model.setRateLimitResetTodayReactionPollingEnabled(false)

        model.setRateLimitResetTodayReactionPollingEnabled(true)
        try await waitUntil { await fetches.value >= 2 }
        #expect(model.isRateLimitResetTodayReactionLoading)
        #expect(model.rateLimitResetTodayReaction?.count == 10)
        model.clickRateLimitResetTodayReaction()
        #expect(await clicks.value == 0)
        #expect(model.rateLimitResetTodayReaction?.count == 10)
        await gate.open()
        try await waitUntil { model.rateLimitResetTodayReaction?.count == 50 }
        #expect(model.rateLimitResetTodayReactionDelta.amount == 0)
        model.setRateLimitResetTodayReactionPollingEnabled(false)
    }

    @Test("click floats +1 before the post returns")
    func clickFloatsImmediately() async throws {
        let gate = Gate()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: {
                reactionSnapshot(count: 10)
            },
            click: {
                await gate.wait()
                return RateLimitResetTodayReactionPostResult(
                    ok: true,
                    data: reactionSnapshot(count: 11))
            })

        defer { Task { await gate.open() } }
        model.setRateLimitResetTodayReactionPollingEnabled(true)
        try await waitUntil { model.rateLimitResetTodayReaction?.count == 10 }
        model.setRateLimitResetTodayReactionPollingEnabled(false)
        model.clickRateLimitResetTodayReaction()
        #expect(model.rateLimitResetTodayReaction?.count == 11)
        #expect(model.rateLimitResetTodayReactionDelta.amount == 1)
        #expect(model.isRateLimitResetTodayReactionBusy)
        await gate.open()
        try await waitUntil { !model.isRateLimitResetTodayReactionBusy }
        #expect(model.rateLimitResetTodayReaction?.count == 11)
        #expect(model.rateLimitResetTodayReactionDelta.amount == 1)
    }

    @Test("click posts and updates the visible count")
    func clickUpdatesCount() async throws {
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: {
                RateLimitResetTodayReactionSnapshot(
                    enabled: true,
                    ready: true,
                    polarity: .no,
                    epochId: "abc",
                    seed: 10,
                    count: 10,
                    remaining: 2,
                    dailyLimit: 5,
                    pollMs: 1_000)
            },
            click: {
                RateLimitResetTodayReactionPostResult(
                    ok: true,
                    data: RateLimitResetTodayReactionSnapshot(
                        enabled: true,
                        ready: true,
                        polarity: .no,
                        epochId: "abc",
                        seed: 10,
                        count: 11,
                        remaining: 1,
                        dailyLimit: 5,
                        pollMs: 1_000))
            })

        model.setRateLimitResetTodayReactionPollingEnabled(true)
        try await waitUntil { model.rateLimitResetTodayReaction?.count == 10 }
        model.setRateLimitResetTodayReactionPollingEnabled(false)
        model.clickRateLimitResetTodayReaction()
        #expect(model.rateLimitResetTodayReaction?.count == 11)
        try await waitUntil { !model.isRateLimitResetTodayReactionBusy }
        #expect(model.rateLimitResetTodayReaction?.count == 11)
        #expect(model.rateLimitResetTodayReactionDelta.amount == 1)
    }

    @Test("daily limit click keeps the previous count and marks exhausted")
    func dailyLimitKeepsPreviousCount() async throws {
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: {
                RateLimitResetTodayReactionSnapshot(
                    enabled: true,
                    ready: true,
                    polarity: .no,
                    epochId: "abc",
                    seed: 10,
                    count: 12,
                    remaining: 1,
                    dailyLimit: 2,
                    pollMs: 1_000)
            },
            click: {
                RateLimitResetTodayReactionPostResult(
                    ok: false,
                    error: "daily_limit",
                    data: RateLimitResetTodayReactionSnapshot(
                        enabled: true,
                        ready: true,
                        polarity: .no,
                        epochId: "abc",
                        seed: 10,
                        count: 12,
                        remaining: 0,
                        dailyLimit: 2,
                        pollMs: 1_000))
            })

        model.setRateLimitResetTodayReactionPollingEnabled(true)
        try await waitUntil { model.rateLimitResetTodayReaction?.count == 12 }
        model.setRateLimitResetTodayReactionPollingEnabled(false)
        model.clickRateLimitResetTodayReaction()
        try await waitUntil { !model.isRateLimitResetTodayReactionBusy }
        #expect(model.rateLimitResetTodayReaction?.count == 12)
        #expect(model.rateLimitResetTodayReaction?.isExhausted == true)
        #expect(model.rateLimitResetTodayReactionDelta.amount == 0)
    }

    @Test("disabled fetch hides the button and does not keep polling")
    func disabledFetchHidesButton() async throws {
        let counter = CallCounter()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: {
                await counter.increment()
                throw RateLimitResetTodayReactionError.disabled
            },
            click: {
                RateLimitResetTodayReactionPostResult(ok: false)
            })

        model.setRateLimitResetTodayReactionPollingEnabled(true)
        try await waitUntil { await counter.value >= 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.rateLimitResetTodayReaction == nil)
        let frozen = await counter.value
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await counter.value == frozen)
    }

    private func makeModel(
        settings: RunwaySettings,
        fetch: @escaping @Sendable () async throws -> RateLimitResetTodayReactionSnapshot,
        click: @escaping @Sendable () async throws -> RateLimitResetTodayReactionPostResult) -> RunwayModel
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-reaction-model-\(UUID().uuidString)", isDirectory: true)
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in throw URLError(.userAuthenticationRequired) },
            fetchQuota: { _ in throw URLError(.badServerResponse) },
            fetchResetCredits: { _ in throw URLError(.badServerResponse) },
            fetchRateLimitResetToday: { RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date()) },
            fetchRateLimitResetTodayReaction: fetch,
            clickRateLimitResetTodayReaction: click,
            scanAPIEquivalent: { _, _, _, _ in [:] },
            fetchDailyWorkspaceUsage: { _, _, _, _, _ in throw URLError(.badServerResponse) },
            fetchCodexProfileTokenUsage: { _ in throw URLError(.badServerResponse) },
            dryRunSessions: {
                SessionRepairReport(
                    missingIndexIDs: [],
                    orphanIndexIDs: [],
                    duplicateIndexIDs: [],
                    staleTitleIDs: [],
                    backupPath: nil,
                    plannedEntries: 0)
            },
            scanRecentSessions: { _ in SessionActivitySummary(items: []) })
        return RunwayModel(
            settings: settings,
            services: services,
            accountStore: AccountStore(
                rootURL: root.appendingPathComponent("accounts", isDirectory: true),
                officialAuthURL: root.appendingPathComponent("auth.json")),
            quotaEstimateHistoryStore: QuotaEstimateHistoryStore(
                fileURL: root.appendingPathComponent("history.json")))
    }

    private func scopedDefaults() -> UserDefaults {
        let suite = "CodexRunwayReactionModel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitUntil(attempts: Int = 100, _ predicate: () async -> Bool) async throws {
        for _ in 0..<attempts {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for reaction model state")
    }
}

private func reactionSnapshot(count: Int, pollMs: Int = 1_000) -> RateLimitResetTodayReactionSnapshot {
    RateLimitResetTodayReactionSnapshot(
        enabled: true,
        ready: true,
        polarity: .no,
        epochId: "abc",
        seed: count,
        count: count,
        remaining: 2,
        dailyLimit: 5,
        pollMs: pollMs)
}

private actor CallCounter {
    private var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }

    var value: Int { count }
}

private actor Gate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CountBox {
    private var values: [Int]

    init(_ values: [Int]) {
        self.values = values
    }

    func next() -> Int {
        guard let first = values.first else { return 0 }
        if values.count > 1 {
            values.removeFirst()
        }
        return first
    }
}
