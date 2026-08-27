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
        try await waitUntil { model.rateLimitResetTodayReaction?.count == 11 }
        #expect(model.rateLimitResetTodayReactionDelta.amount == 1)
        #expect(!model.isRateLimitResetTodayReactionBusy)
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

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for reaction model state")
    }
}

private actor CallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    var value: Int { count }
}
