import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Runway model refresh")
@MainActor
struct RunwayModelRefreshTests {
    @Test("token heatmap uses official profile daily buckets")
    func tokenHeatmapUsesCodexProfileDailyUsage() async throws {
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let expected = ["2026-07-26": 159_644_197]
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in Self.auth() },
            fetchQuota: { _ in Self.quotaSnapshot() },
            fetchResetCredits: { _ in ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date()) },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, _, _ in
                Dictionary(uniqueKeysWithValues: queries.map {
                    ($0.id, ApiEquivalentSummary.unavailable(window: $0.window, calculatedAt: now))
                })
            },
            fetchDailyWorkspaceUsage: { _, _, _, window, now in
                Self.costSummary(window: window, calculatedAt: now)
            },
            fetchCodexProfileTokenUsage: { _ in
                CodexProfileTokenUsage(
                    dailyTokens: expected,
                    statsAsOf: "2026-07-27",
                    generatedAt: Date(timeIntervalSince1970: 1_785_139_420))
            },
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
        let model = makeModel(settings: settings, services: services)

        model.refreshTokenHeatmap()
        try await waitForTokenHeatmapRefresh(in: model)

        #expect(model.tokenHeatmapAllDevicesTokens == expected)
        #expect(model.tokenHeatmapLocalTokens.isEmpty)
        #expect(model.tokenHeatmapOfficialStatsAsOf == "2026-07-27")
        #expect(model.tokenHeatmapOfficialGeneratedAt == Date(timeIntervalSince1970: 1_785_139_420))
    }

    @Test("account changes clear and immediately reload token heatmap state")
    func accountChangeClearsTokenHeatmapState() async throws {
        let provider = MutableAuthProvider(Self.auth(accountId: "acct-a"))
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in await provider.load() },
            fetchQuota: { _ in Self.quotaSnapshot() },
            fetchResetCredits: { _ in ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date()) },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, _, _ in
                Dictionary(uniqueKeysWithValues: queries.map {
                    ($0.id, ApiEquivalentSummary.unavailable(window: $0.window, calculatedAt: now))
                })
            },
            fetchDailyWorkspaceUsage: { _, _, _, window, now in
                Self.costSummary(window: window, calculatedAt: now)
            },
            fetchCodexProfileTokenUsage: { auth in
                let value = auth.tokens.accountId == "acct-a" ? 100 : 200
                let statsAsOf = auth.tokens.accountId == "acct-a" ? "2026-07-27" : "2026-07-28"
                let generatedAt = auth.tokens.accountId == "acct-a"
                    ? Date(timeIntervalSince1970: 1_785_139_420)
                    : Date(timeIntervalSince1970: 1_785_225_820)
                return CodexProfileTokenUsage(
                    dailyTokens: ["2026-07-26": value],
                    statsAsOf: statsAsOf,
                    generatedAt: generatedAt)
            },
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
        let model = makeModel(settings: settings, services: services)

        model.refreshTokenHeatmap()
        try await waitForTokenHeatmapRefresh(in: model)
        #expect(model.tokenHeatmapAllDevicesTokens["2026-07-26"] == 100)
        #expect(model.tokenHeatmapOfficialStatsAsOf == "2026-07-27")
        #expect(model.tokenHeatmapOfficialGeneratedAt == Date(timeIntervalSince1970: 1_785_139_420))

        await provider.set(Self.auth(accountId: "acct-b"))
        model.refreshQuota()
        try await waitForTokenHeatmapClear(in: model)
        #expect(model.tokenHeatmapAllDevicesTokens.isEmpty)
        #expect(model.tokenHeatmapLocalTokens.isEmpty)
        #expect(model.tokenHeatmapCalculatedAt == nil)
        #expect(model.tokenHeatmapOfficialStatsAsOf == nil)
        #expect(model.tokenHeatmapOfficialGeneratedAt == nil)

        model.refreshTokenHeatmap(policy: .ifChanged)
        try await waitForTokenHeatmapRefresh(in: model)
        #expect(model.tokenHeatmapAllDevicesTokens["2026-07-26"] == 200)
        #expect(model.tokenHeatmapOfficialStatsAsOf == "2026-07-28")
        #expect(model.tokenHeatmapOfficialGeneratedAt == Date(timeIntervalSince1970: 1_785_225_820))
    }

    @Test("switching accounts cancels an in-flight old-account heatmap")
    func accountSwitchCancelsInFlightHeatmap() async throws {
        let firstAuth = Self.auth(accountId: "acct-a")
        let secondAuth = Self.auth(accountId: "acct-b")
        let store = isolatedAccountStore()
        _ = try store.upsert(auth: firstAuth, makeActive: true)
        let secondAccount = try store.upsert(auth: secondAuth, makeActive: false)
        let profileService = BlockingProfileUsageService()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let services = RunwayModelServices(
            loadValidAuth: { _, cached in cached ?? firstAuth },
            fetchQuota: { _ in Self.quotaSnapshot() },
            fetchResetCredits: { _ in ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date()) },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, _, _ in
                Dictionary(uniqueKeysWithValues: queries.map {
                    ($0.id, ApiEquivalentSummary.unavailable(window: $0.window, calculatedAt: now))
                })
            },
            fetchDailyWorkspaceUsage: { _, _, _, window, now in
                Self.costSummary(window: window, calculatedAt: now)
            },
            fetchCodexProfileTokenUsage: { auth in
                await profileService.fetch(accountId: auth.tokens.accountId)
            },
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
        let model = RunwayModel(settings: settings, services: services, accountStore: store)

        model.refreshTokenHeatmap()
        try await profileService.waitUntilFirstRequest()
        model.switchAccount(id: secondAccount.id, restartCodex: false)
        try await waitForActiveAccount(secondAccount.id, in: store)
        await profileService.releaseFirstRequest()
        try await waitForAccountSwitch(secondAccount.id, in: model)

        #expect(model.tokenHeatmapAllDevicesTokens["2026-07-26"] == 200)
        #expect(!model.tokenHeatmapAllDevicesTokens.values.contains(100))
    }

    @Test("full refresh starts independent popover sections without waiting for API cost")
    func fullRefreshStartsIndependentSectionsWithoutWaitingForAPICost() async throws {
        let recorder = RefreshEventRecorder()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsCostSummary(true)
        settings.updateShowsSessionRepairSummary(true)
        settings.updateShowsRecentSessions(true)

        let quota = Self.quotaSnapshot()
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in Self.auth() },
            fetchQuota: { _ in
                await recorder.record("quota-start")
                try await Task.sleep(for: .milliseconds(20))
                await recorder.record("quota-finish")
                return quota
            },
            fetchResetCredits: { _ in
                await recorder.record("reset-start")
                try await Task.sleep(for: .milliseconds(220))
                await recorder.record("reset-finish")
                return ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date())
            },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, _, _ in
                await recorder.record("cost-start")
                try await Task.sleep(for: .milliseconds(160))
                await recorder.record("cost-finish")
                return Self.costSummaries(for: queries, calculatedAt: now)
            },
            fetchDailyWorkspaceUsage: { _, _, _, window, now in
                Self.costSummary(window: window, calculatedAt: now)
            },
            fetchCodexProfileTokenUsage: { _ in
                CodexProfileTokenUsage(dailyTokens: [:])
            },
            dryRunSessions: {
                await recorder.record("repair-start")
                return SessionRepairReport(
                    missingIndexIDs: [],
                    orphanIndexIDs: [],
                    duplicateIndexIDs: [],
                    staleTitleIDs: [],
                    backupPath: nil,
                    plannedEntries: 0)
            },
            scanRecentSessions: { _ in
                await recorder.record("recent-start")
                return SessionActivitySummary(items: [])
            })
        let model = makeModel(settings: settings, services: services)

        model.refresh()
        try await recorder.waitFor("cost-finish")
        try await recorder.waitFor("reset-finish")

        let events = await recorder.events
        let repairStart = try #require(events.firstIndex(of: "repair-start"))
        let recentStart = try #require(events.firstIndex(of: "recent-start"))
        let costStart = try #require(events.firstIndex(of: "cost-start"))
        let costFinish = try #require(events.firstIndex(of: "cost-finish"))
        let resetFinish = try #require(events.firstIndex(of: "reset-finish"))
        #expect(events.filter { $0 == "quota-start" }.count == 1)
        #expect(repairStart < costFinish)
        #expect(recentStart < costFinish)
        #expect(costStart < resetFinish)
    }

    @Test("default API cost summary scans today's range")
    func defaultAPICostSummaryScansToday() async throws {
        let recorder = CostBatchRecorder()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsCostSummary(true)
        let services = Self.costRangeServices(recorder: recorder)
        let model = makeModel(settings: settings, services: services)

        model.refreshCost()

        let captured = try await recorder.waitForBatch()
        let calendar = Calendar.autoupdatingCurrent
        let selected = try #require(captured.queries.first {
            $0.window.start == calendar.startOfDay(for: captured.now)
        })
        #expect(captured.queries.count == 2)
        #expect(selected.window.end == captured.now)
        #expect(captured.policy == .force)
        try await waitForCostRefresh(in: model)
        #expect(await recorder.captureCount == 1)
    }

    @Test("if-changed refresh reuses results within the configured interval")
    func ifChangedRefreshReusesRecentResults() async throws {
        let recorder = CostBatchRecorder()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let model = makeModel(settings: settings, services: Self.costRangeServices(recorder: recorder))

        model.refreshCost(policy: .ifChanged)
        _ = try await recorder.waitForBatch()
        try await waitForCostRefresh(in: model)

        model.refreshCost(policy: .ifChanged)
        try await Task.sleep(for: .milliseconds(20))

        #expect(await recorder.captureCount == 1)
        #expect(!model.isRefreshing(.apiCost))

        model.refreshCost(policy: .force)
        _ = try await recorder.waitForBatch(count: 2)
        #expect(await recorder.captureCount == 2)
    }

    @Test("current cycle API cost summary scans elapsed quota weekly range")
    func currentCycleAPICostSummaryScansQuotaWindow() async throws {
        let recorder = CostBatchRecorder()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateApiCostSummaryRange(.current)
        let quota = Self.quotaSnapshot(secondaryReset: Date().addingTimeInterval(10_080 * 60))
        let services = Self.costRangeServices(quota: quota, recorder: recorder)
        let model = makeModel(settings: settings, services: services)

        model.refreshCost()

        let captured = try await recorder.waitForBatch()
        let secondary = try #require(quota.secondary)
        let reset = try #require(secondary.resetsAt)
        let minutes = try #require(secondary.windowMinutes)
        let query = try #require(captured.queries.first)
        let start = reset.addingTimeInterval(-TimeInterval(minutes * 60))
        #expect(captured.queries.count == 1)
        #expect(query.window.start == start)
        #expect(query.window.end == min(max(captured.now, start), reset))
        #expect(captured.policy == .force)
        try await waitForCostRefresh(in: model)
        #expect(await recorder.captureCount == 1)
    }

    @Test("previous cycle API cost summary scans the full previous quota weekly range")
    func previousCycleAPICostSummaryScansFullPreviousQuotaWindow() async throws {
        let recorder = CostBatchRecorder()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateApiCostSummaryRange(.previous)
        let quota = Self.quotaSnapshot(secondaryReset: Date().addingTimeInterval(10_080 * 60))
        let services = Self.costRangeServices(quota: quota, recorder: recorder)
        let model = makeModel(settings: settings, services: services)

        model.refreshCost()

        let captured = try await recorder.waitForBatch()
        let secondary = try #require(quota.secondary)
        let reset = try #require(secondary.resetsAt)
        let minutes = try #require(secondary.windowMinutes)
        let duration = TimeInterval(minutes * 60)
        let cycleStart = reset.addingTimeInterval(-duration)
        let previous = try #require(captured.queries.first {
            $0.window.start == cycleStart.addingTimeInterval(-duration)
        })
        #expect(captured.queries.count == 2)
        #expect(previous.window.end == cycleStart)
        #expect(captured.policy == .force)
        try await waitForCostRefresh(in: model)
        #expect(await recorder.captureCount == 1)
    }

    @Test("API cost summary shows empty usage when selected range has no tokens")
    func apiCostSummaryShowsEmptyUsageWhenSelectedRangeHasNoTokens() async throws {
        let recorder = CostBatchRecorder()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsCostSummary(true)
        settings.updateApiCostSummaryRange(.current)
        let quota = Self.quotaSnapshot()
        let secondary = try #require(quota.secondary)
        let reset = try #require(secondary.resetsAt)
        let minutes = try #require(secondary.windowMinutes)
        let currentStart = reset.addingTimeInterval(-TimeInterval(minutes * 60))
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in Self.auth() },
            fetchQuota: { _ in quota },
            fetchResetCredits: { _ in ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date()) },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, policy, _ in
                await recorder.record(queries: queries, now: now, policy: policy)
                return Dictionary(uniqueKeysWithValues: queries.map { query in
                    if query.window.start == currentStart {
                        return (query.id, Self.costSummary(window: query.window, calculatedAt: now))
                    }
                    return (query.id, ApiEquivalentSummary.unavailable(window: query.window, calculatedAt: now))
                })
            },
            fetchDailyWorkspaceUsage: { _, _, _, _, _ in
                throw URLError(.badServerResponse)
            },
            fetchCodexProfileTokenUsage: { _ in
                CodexProfileTokenUsage(dailyTokens: [:])
            },
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
        let model = makeModel(settings: settings, services: services)

        model.refreshCost()
        _ = try await recorder.waitForBatch()
        for _ in 0..<100 {
            if model.costText.contains("$1") { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        settings.updateApiCostSummaryRange(.today)
        model.refreshCost()
        _ = try await recorder.waitForBatch(count: 2)
        // Empty local scan for the selected range is "no usage", not a hard failure —
        // even when the online analytics supplement fails.
        let emptyUsage = settings.l10n.text(.usageAnalyticsEmpty)
        for _ in 0..<100 {
            if model.costText == emptyUsage { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let lineText = model.costLines.map(\.value).joined(separator: " ")
        #expect(model.costText == emptyUsage)
        #expect(model.costScanNote == nil)
        #expect(!model.costText.contains("$1"))
        #expect(!lineText.contains("NSURLErrorDomain"))
        #expect(!lineText.contains("-1011"))
        #expect(!lineText.contains(settings.l10n.text(.usageAnalyticsUnavailable)))
    }

    @Test("full refresh reserves synchronously and forwards if-changed policy")
    func fullRefreshReservesSynchronouslyAndForwardsPolicy() async throws {
        let batchRecorder = CostBatchRecorder()
        let completionRecorder = RefreshEventRecorder()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsCostSummary(true)
        let model = makeModel(
            settings: settings,
            services: Self.costRangeServices(recorder: batchRecorder))
        model.onFullRefreshCompleted = {
            Task { await completionRecorder.record("complete") }
        }

        model.refresh(policy: .ifChanged)

        #expect(model.isRefreshingAll)
        let captured = try await batchRecorder.waitForBatch()
        try await completionRecorder.waitFor("complete")
        #expect(captured.policy == .ifChanged)
        #expect(!model.isRefreshingAll)
    }

    @Test("cancelled detail waiter does not cancel shared background scan")
    func cancelledDetailWaiterDoesNotCancelSharedBackgroundScan() async throws {
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in Self.auth() },
            fetchQuota: { _ in Self.quotaSnapshot() },
            fetchResetCredits: { _ in ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date()) },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, _, _ in
                try await Task.sleep(for: .milliseconds(80))
                return Self.costSummaries(for: queries, calculatedAt: now)
            },
            fetchDailyWorkspaceUsage: { _, _, _, window, now in
                Self.costSummary(window: window, calculatedAt: now)
            },
            fetchCodexProfileTokenUsage: { _ in
                CodexProfileTokenUsage(dailyTokens: [:])
            },
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
        let model = makeModel(settings: settings, services: services)
        let range = ApiCostRange.today(now: Date())
        let queryTask = Task {
            try await model.queryCost(range: range)
        }

        try await Task.sleep(for: .milliseconds(20))
        queryTask.cancel()
        do {
            _ = try await queryTask.value
            // Unstructured scan may finish before cancel is observed; both outcomes are OK.
        } catch is CancellationError {
            // Expected when the waiter is cancelled before the scan finishes.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Background scan should still complete and populate the detail cache.
        let summary = try await model.queryCost(range: range)
        #expect(summary.isDisplayableCost)
    }

    @Test("tick does not republish identical status text")
    func tickDoesNotRepublishIdenticalStatusText() async throws {
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let model = makeModel(
            settings: settings,
            services: Self.costRangeServices(recorder: CostBatchRecorder()))
        model.refreshQuota()
        try await waitForQuota(in: model)

        let now = Date(timeIntervalSince1970: 1_782_710_000)
        model.tick(now: now)
        let first = model.statusText
        var changeCount = 0
        let token = model.objectWillChange.sink { _ in changeCount += 1 }
        model.tick(now: now)
        model.tick(now: now.addingTimeInterval(0.2))
        #expect(model.statusText == first)
        #expect(changeCount == 0)
        _ = token
    }

    @Test("quota labels follow the primary window duration")
    func quotaLabelsFollowPrimaryWindowDuration() async throws {
        let weekly = Self.quotaSnapshot(primaryMinutes: 10_080)
        let weeklySettings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let weeklyModel = makeModel(
            settings: weeklySettings,
            services: Self.costRangeServices(quota: weekly, recorder: CostBatchRecorder()))

        weeklyModel.refreshQuota()
        try await waitForQuota(in: weeklyModel)

        #expect(weeklyModel.quotaText.contains(weeklySettings.l10n.text(.weeklyUsage)))
        #expect(!weeklyModel.quotaText.contains(weeklySettings.l10n.text(.fiveHourUsage)))
        #expect(weeklyModel.quotaLines[1].title == weeklySettings.l10n.text(.weeklyUsage))
        #expect(weeklyModel.quotaMeters.first?.title == weeklySettings.l10n.text(.weeklyUsage))

        let fiveHour = Self.quotaSnapshot(primaryMinutes: 300)
        let fiveHourSettings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let fiveHourModel = makeModel(
            settings: fiveHourSettings,
            services: Self.costRangeServices(quota: fiveHour, recorder: CostBatchRecorder()))

        fiveHourModel.refreshQuota()
        try await waitForQuota(in: fiveHourModel)

        #expect(fiveHourModel.quotaText.contains(fiveHourSettings.l10n.text(.fiveHourUsage)))
        #expect(fiveHourModel.quotaLines[1].title == fiveHourSettings.l10n.text(.fiveHourUsage))
        #expect(fiveHourModel.quotaMeters.first?.title == fiveHourSettings.l10n.text(.fiveHourUsage))
    }

    private func scopedDefaults() -> UserDefaults {
        let suite = "codex-runway-refresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Never use the real ~/.codex / ~/.codex-runway paths in unit tests.
    private func isolatedAccountStore() -> AccountStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-model-test-\(UUID().uuidString)", isDirectory: true)
        return AccountStore(
            rootURL: root.appendingPathComponent("accounts", isDirectory: true),
            officialAuthURL: root.appendingPathComponent("auth.json"))
    }

    private func makeModel(settings: RunwaySettings, services: RunwayModelServices) -> RunwayModel {
        RunwayModel(settings: settings, services: services, accountStore: isolatedAccountStore())
    }

    private func waitForQuota(in model: RunwayModel) async throws {
        for _ in 0..<100 {
            if !model.quotaMeters.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for quota refresh")
    }

    private func waitForTokenHeatmapClear(in model: RunwayModel) async throws {
        for _ in 0..<100 {
            if model.tokenHeatmapAllDevicesTokens.isEmpty,
               model.tokenHeatmapLocalTokens.isEmpty,
               model.tokenHeatmapCalculatedAt == nil,
               model.tokenHeatmapOfficialStatsAsOf == nil,
               model.tokenHeatmapOfficialGeneratedAt == nil
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for account-scoped token heatmap clear")
    }

    private func waitForActiveAccount(_ id: String, in store: AccountStore) async throws {
        for _ in 0..<100 {
            if try store.loadIndex().activeAccountId == id { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for account store switch")
    }

    private func waitForAccountSwitch(_ id: String, in model: RunwayModel) async throws {
        for _ in 0..<200 {
            if model.activeAccountId == id,
               !model.isSwitchingAccount,
               model.tokenHeatmapAllDevicesTokens["2026-07-26"] == 200
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for switched-account heatmap")
    }

    private func waitForCostRefresh(in model: RunwayModel) async throws {
        for _ in 0..<100 {
            if !model.isRefreshing(.apiCost) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for API cost refresh")
    }

    private func waitForTokenHeatmapRefresh(in model: RunwayModel) async throws {
        for _ in 0..<100 {
            if !model.isRefreshing(.tokenHeatmap) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for token heatmap refresh")
    }

    nonisolated private static func quotaSnapshot(primaryMinutes: Int = 300, secondaryReset: Date? = nil) -> QuotaSnapshot {
        let now = Date(timeIntervalSince1970: 1_782_710_000)
        return QuotaSnapshot(
            plan: "pro",
            primary: RateWindow(usedPercent: 20, windowMinutes: primaryMinutes, resetsAt: now.addingTimeInterval(3_600)),
            secondary: RateWindow(usedPercent: 30, windowMinutes: 10_080, resetsAt: secondaryReset ?? now.addingTimeInterval(10_080 * 60)),
            additionalWindows: [],
            creditsBalance: nil,
            updatedAt: now)
    }

    nonisolated private static func auth(accountId: String = "acct-test") -> CodexAuth {
        // Long JWT + refresh so loginUsability stays .usable (must never mirror into real ~/.codex).
        let access = jwt(payload: [
            "exp": 4_100_000_000,
            "email": "test@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountId,
                "chatgpt_plan_type": "pro",
            ],
        ])
        return CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: access,
                accessToken: access,
                refreshToken: "test-refresh-token-\(accountId)-not-for-production-use",
                accountId: accountId),
            lastRefresh: nil)
    }

    nonisolated private static func jwt(payload: [String: Any]) -> String {
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        let body = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return [header, body, Data()]
            .map {
                $0.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            .joined(separator: ".")
    }

    nonisolated private static func costRangeServices(
        quota: QuotaSnapshot = quotaSnapshot(),
        recorder: CostBatchRecorder) -> RunwayModelServices
    {
        RunwayModelServices(
            loadValidAuth: { _, _ in Self.auth() },
            fetchQuota: { _ in quota },
            fetchResetCredits: { _ in ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date()) },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, policy, _ in
                await recorder.record(queries: queries, now: now, policy: policy)
                return Self.costSummaries(for: queries, calculatedAt: now)
            },
            fetchDailyWorkspaceUsage: { _, _, _, window, now in
                Self.costSummary(window: window, calculatedAt: now)
            },
            fetchCodexProfileTokenUsage: { _ in
                CodexProfileTokenUsage(dailyTokens: [:])
            },
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
    }

    nonisolated private static func costSummary(window: DateInterval, calculatedAt: Date) -> ApiEquivalentSummary {
        ApiEquivalentSummary(
            source: .localSessions,
            confidence: .priced,
            window: window,
            estimatedUSD: 1,
            totals: ApiEquivalentTotals(
                totalTokens: 10,
                uncachedInputTokens: 5,
                cachedInputTokens: 2,
                outputTokens: 3,
                turns: 1,
                threads: 1),
            dailyRows: [],
            modelRows: [],
            clientRows: [],
            rawCredits: 0,
            warnings: [],
            pricingVersion: "test",
            calculatedAt: calculatedAt)
    }

    nonisolated private static func costSummaries(
        for queries: [ApiCostQuery],
        calculatedAt: Date
    ) -> [String: ApiEquivalentSummary] {
        Dictionary(uniqueKeysWithValues: queries.map { query in
            (query.id, costSummary(window: query.window, calculatedAt: calculatedAt))
        })
    }
}

private struct CostBatchCapture: Sendable {
    let queries: [ApiCostQuery]
    let now: Date
    let policy: UsageCostRefreshPolicy
}

private actor CostBatchRecorder {
    private var captures: [CostBatchCapture] = []
    var captureCount: Int { captures.count }

    func record(queries: [ApiCostQuery], now: Date, policy: UsageCostRefreshPolicy) {
        captures.append(CostBatchCapture(queries: queries, now: now, policy: policy))
    }

    func waitForBatch(count: Int = 1) async throws -> CostBatchCapture {
        for _ in 0..<100 {
            if captures.count >= count, let captured = captures.last { return captured }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for API cost batch")
        throw CancellationError()
    }
}

private actor RefreshEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func waitFor(_ event: String) async throws {
        for _ in 0..<100 {
            if events.contains(event) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for \(event); events: \(events)")
    }
}

private actor MutableAuthProvider {
    private var auth: CodexAuth

    init(_ auth: CodexAuth) {
        self.auth = auth
    }

    func load() -> CodexAuth {
        auth
    }

    func set(_ auth: CodexAuth) {
        self.auth = auth
    }
}

private actor BlockingProfileUsageService {
    private var firstRequestStarted = false
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?

    func fetch(accountId: String?) async -> CodexProfileTokenUsage {
        if accountId == "acct-a", !firstRequestStarted {
            firstRequestStarted = true
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
            return CodexProfileTokenUsage(dailyTokens: ["2026-07-26": 100])
        }
        return CodexProfileTokenUsage(dailyTokens: ["2026-07-26": 200])
    }

    func waitUntilFirstRequest() async throws {
        for _ in 0..<100 {
            if firstRequestStarted { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for first profile usage request")
    }

    func releaseFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }
}
