import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Rate limit reset today refresh")
@MainActor
struct RateLimitResetTodayRefreshModelTests {
    @Test("forced refresh bypasses the interval, updates the card, and shows the section spinner")
    func forcedRefreshBypassesIntervalAndShowsSpinner() async throws {
        let counter = CallCounter()
        let gate = Gate()
        let snapshots = SnapshotQueue([
            RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date()),
            RateLimitResetTodaySnapshot.devMock(kind: .yes, now: Date()),
        ])
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(true)
        settings.updateRateLimitResetTodayRefreshInterval(21_600)
        let model = makeModel(
            settings: settings,
            fetch: {
                await counter.increment()
                await gate.wait()
                return await snapshots.next()
            })

        defer { Task { await gate.open() } }
        model.refreshRateLimitResetToday(force: true)
        try await waitUntil { await counter.value >= 1 }
        #expect(model.isRefreshing(.rateLimitResetToday))
        #expect(model.rateLimitResetToday == nil)

        await gate.open()
        try await waitUntil { !model.isRefreshing(.rateLimitResetToday) }
        #expect(model.rateLimitResetToday?.state == .no)
        #expect(await counter.value == 1)

        model.refreshRateLimitResetToday(force: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await counter.value == 1)

        await gate.reset()
        model.refreshRateLimitResetToday(force: true)
        try await waitUntil { await counter.value >= 2 }
        #expect(model.isRefreshing(.rateLimitResetToday))
        await gate.open()
        try await waitUntil { !model.isRefreshing(.rateLimitResetToday) }
        #expect(model.rateLimitResetToday?.state == .yes)
        #expect(await counter.value == 2)
    }

    @Test("hidden module does not fetch reset-today on a panel-open refresh")
    func hiddenModuleSkipsPanelOpenFetch() async throws {
        let counter = CallCounter()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsRateLimitResetToday(false)
        let model = makeModel(
            settings: settings,
            fetch: {
                await counter.increment()
                return RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            })

        model.refreshRateLimitResetToday(force: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await counter.value == 0)
        #expect(!model.isRefreshing(.rateLimitResetToday))
    }

    @Test("first fetch failure uses unavailable wording and keeps the error detail")
    func firstFetchFailureUsesUnavailablePresentation() async throws {
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateLanguage(.simplifiedChinese)
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: { throw URLError(.cannotConnectToHost) })

        model.refreshRateLimitResetToday(force: true)
        try await waitUntil { model.rateLimitResetTodayText == "暂不可用" }

        #expect(model.rateLimitResetToday == nil)
        #expect(model.rateLimitResetTodayText == "暂不可用")
        #expect(model.rateLimitResetTodayLines.first?.title == "Codex 重置状态如何？")
        #expect(model.rateLimitResetTodayLines.first?.value == "暂不可用")
        #expect(model.rateLimitResetTodayLines.contains {
            $0.title == "错误" && !$0.value.isEmpty
        })
    }

    @Test("refresh failure keeps the last snapshot and error until recovery")
    func refreshFailurePersistsAcrossTickAndRelabelUntilRecovery() async throws {
        let counter = CallCounter()
        let first = RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
        let recovered = RateLimitResetTodaySnapshot.devMock(kind: .yes, now: Date())
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateLanguage(.simplifiedChinese)
        settings.updateShowsRateLimitResetToday(true)
        let model = makeModel(
            settings: settings,
            fetch: {
                switch await counter.increment() {
                case 1: return first
                case 2: throw URLError(.cannotConnectToHost)
                default: return recovered
                }
            })

        model.refreshRateLimitResetToday(force: true)
        try await waitUntil { await counter.value == 1 && !model.isRefreshing(.rateLimitResetToday) }
        #expect(model.rateLimitResetToday == first)

        model.refreshRateLimitResetToday(force: true)
        try await waitUntil { await counter.value == 2 && !model.isRefreshing(.rateLimitResetToday) }
        #expect(model.rateLimitResetToday == first)
        #expect(model.rateLimitResetTodayLines.contains { $0.title == "错误" })

        model.tick(now: Date().addingTimeInterval(60))
        #expect(model.rateLimitResetToday == first)
        #expect(model.rateLimitResetTodayLines.contains { $0.title == "错误" })

        settings.updateLanguage(.english)
        model.relabel()
        #expect(model.rateLimitResetToday == first)
        #expect(model.rateLimitResetTodayLines.contains { $0.title == "Error" })

        model.refreshRateLimitResetToday(force: true)
        try await waitUntil { await counter.value == 3 && !model.isRefreshing(.rateLimitResetToday) }
        #expect(model.rateLimitResetToday == recovered)
        #expect(!model.rateLimitResetTodayLines.contains { $0.title == "Error" })
    }

    @Test("new grace snapshots extend and disable the shared presentation immediately")
    func refreshedGraceDurationUpdatesSummaryAndDetails() async throws {
        let now = Date()
        let snapshots = SnapshotQueue([
            graceSnapshot(hours: 3, now: now),
            graceSnapshot(hours: 24, now: now),
            graceSnapshot(hours: 0, now: now),
        ])
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateLanguage(.simplifiedChinese)
        settings.updateShowsRateLimitResetToday(true)
        settings.updateRateLimitResetTodayAlertsEnabled(false)
        let model = makeModel(settings: settings, fetch: { await snapshots.next() })

        for expectedShowsYes in [false, true, false] {
            model.refreshRateLimitResetToday(force: true)
            try await waitUntil {
                !model.isRefreshing(.rateLimitResetToday)
                    && model.rateLimitResetToday?.verdictPresentation(now: now).showsYes == expectedShowsYes
            }
            let presentation = try #require(model.rateLimitResetToday?.verdictPresentation(now: now))
            let firstLine = try #require(model.rateLimitResetTodayLines.first)

            #expect(!presentation.isCompleted)
            #expect(firstLine.title == presentation.questionText(l10n: settings.l10n))
            #expect(firstLine.value == presentation.titleText(l10n: settings.l10n))
            #expect(model.rateLimitResetTodayText.hasPrefix(firstLine.value))
        }
    }

    private func makeModel(
        settings: RunwaySettings,
        fetch: @escaping @Sendable () async throws -> RateLimitResetTodaySnapshot) -> RunwayModel
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-reset-today-refresh-\(UUID().uuidString)", isDirectory: true)
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in throw URLError(.userAuthenticationRequired) },
            fetchQuota: { _ in throw URLError(.badServerResponse) },
            fetchResetCredits: { _ in throw URLError(.badServerResponse) },
            fetchRateLimitResetToday: fetch,
            scanAPIEquivalent: { _, _, _, _ in throw URLError(.badServerResponse) },
            fetchDailyWorkspaceUsage: { _, _, _, _, _ in throw URLError(.badServerResponse) },
            fetchCodexProfileTokenUsage: { _ in throw URLError(.badServerResponse) },
            dryRunSessions: { throw URLError(.badServerResponse) },
            scanRecentSessions: { _ in throw URLError(.badServerResponse) })
        return RunwayModel(
            settings: settings,
            services: services,
            accountStore: AccountStore(
                rootURL: root.appendingPathComponent("accounts", isDirectory: true),
                officialAuthURL: root.appendingPathComponent("auth.json")))
    }

    private func scopedDefaults() -> UserDefaults {
        let suite = "CodexRunwayResetTodayRefresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitUntil(attempts: Int = 100, _ predicate: () async -> Bool) async throws {
        for _ in 0..<attempts {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for reset-today refresh state")
    }

    private func graceSnapshot(hours: Double, now: Date) -> RateLimitResetTodaySnapshot {
        var snapshot = RateLimitResetTodaySnapshot.devMock(kind: .no, now: now)
        let event = RateLimitResetTodayEvent(
            kind: .resetScheduled,
            announcedAt: now.addingTimeInterval(-5 * 3_600),
            effectiveAt: now.addingTimeInterval(-4 * 3_600),
            schedulePrecision: .datetime,
            scheduleBasis: .explicit,
            scheduleGraceHours: hours,
            scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
            source: RateLimitResetTodaySource(
                handle: "thsottiaux",
                postID: "2090000000000000001",
                url: URL(string: "https://x.com/thsottiaux/status/2090000000000000001")!),
            confidence: 0.98,
            rationale: "Explicit Codex quota reset schedule.",
            text: "A reset is scheduled.")
        snapshot.events = [event]
        snapshot.graceSchedules = hours > 3 ? [event] : []
        return snapshot
    }
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

    func reset() {
        opened = false
        continuation?.resume()
        continuation = nil
    }
}

private actor SnapshotQueue {
    private var snapshots: [RateLimitResetTodaySnapshot]

    init(_ snapshots: [RateLimitResetTodaySnapshot]) {
        self.snapshots = snapshots
    }

    func next() -> RateLimitResetTodaySnapshot {
        guard !snapshots.isEmpty else {
            return RateLimitResetTodaySnapshot(state: .unknown, fetchedAt: Date())
        }
        if snapshots.count == 1 {
            return snapshots[0]
        }
        return snapshots.removeFirst()
    }
}
