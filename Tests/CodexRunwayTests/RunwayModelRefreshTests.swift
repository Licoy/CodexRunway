import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Runway model refresh")
@MainActor
struct RunwayModelRefreshTests {
    @Test("token heatmap uses official profile daily buckets")
    func tokenHeatmapUsesCodexProfileDailyUsage() async throws {
        let recorder = CostBatchRecorder()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let expected = ["2026-07-26": 159_644_197]
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in Self.auth() },
            fetchQuota: { _ in Self.quotaSnapshot() },
            fetchResetCredits: { _ in ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date()) },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, policy, _ in
                await recorder.record(queries: queries, now: now, policy: policy)
                return Dictionary(uniqueKeysWithValues: queries.map {
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
        let captured = try await recorder.waitForBatch()
        try await waitForTokenHeatmapRefresh(in: model)

        let query = try #require(captured.queries.first)
        #expect(query.dayBoundary == .utc)
        #expect(query.window == TokenUsageHeatmapBuilder.utcYearToDateWindow(now: captured.now))
        #expect(model.tokenHeatmapAllDevicesTokens == expected)
        #expect(model.tokenHeatmapLocalTokens.isEmpty)
        #expect(model.tokenHeatmapOfficialStatsAsOf == "2026-07-27")
        #expect(model.tokenHeatmapOfficialGeneratedAt == Date(timeIntervalSince1970: 1_785_139_420))
    }

    @Test("quota estimate fetches analytics when the module is shown")
    func quotaEstimateFetchesWhenEnabled() async throws {
        let counter = CallCounter()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsQuotaEstimateSummary(true)
        settings.updateShowsTokenUsageHeatmap(false)
        settings.updateShowsCostSummary(false)
        settings.updateShowsSessionRepairSummary(false)
        settings.updateShowsRecentSessions(false)
        settings.updateShowsRateLimitResetToday(false)
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
                await counter.increment()
                return Self.estimateSummary(window: window, calculatedAt: now)
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

        model.refresh()
        try await waitForQuotaEstimate(in: model)

        let snapshot = try #require(model.quotaEstimate)
        #expect(snapshot.canExtrapolate)
        #expect(snapshot.usedCredits == 30)
        #expect(snapshot.estimatedCredits == 100)
        #expect(await counter.value() == 1)
        #expect(model.quotaEstimateError == nil)
    }

    @Test("quota estimate does not fetch analytics when hidden")
    func quotaEstimateSkippedWhenHidden() async throws {
        let counter = CallCounter()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsQuotaEstimateSummary(false)
        settings.updateShowsTokenUsageHeatmap(false)
        settings.updateShowsCostSummary(false)
        settings.updateShowsSessionRepairSummary(false)
        settings.updateShowsRecentSessions(false)
        settings.updateShowsRateLimitResetToday(false)
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
                await counter.increment()
                return Self.estimateSummary(window: window, calculatedAt: now)
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

        model.refresh()
        try await waitForFullRefresh(in: model)

        #expect(model.quotaEstimate == nil)
        #expect(await counter.value() == 0)
    }

    @Test("first full refresh publishes local heatmap data when profile fails")
    func firstProfileFailureKeepsLocalHeatmapVisible() async throws {
        let profileService = FailOnceProfileUsageService()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in Self.auth() },
            fetchQuota: { _ in Self.quotaSnapshot() },
            fetchResetCredits: { _ in ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date()) },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, _, _ in
                Dictionary(uniqueKeysWithValues: queries.map {
                    ($0.id, Self.localHeatmapSummary(window: $0.window, calculatedAt: now))
                })
            },
            fetchDailyWorkspaceUsage: { _, _, _, window, now in
                Self.costSummary(window: window, calculatedAt: now)
            },
            fetchCodexProfileTokenUsage: { _ in
                try await profileService.fetch()
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

        model.refresh()
        try await waitForFullRefresh(in: model)

        #expect(model.tokenHeatmapLocalTokens == ["2026-07-26": 364])
        #expect(model.tokenHeatmapAllDevicesTokens.isEmpty)

        // Metadata can outlive an empty official daily series. Widgets must still
        // render the local series instead of labelling an empty chart as all devices.
        model.tokenHeatmapOfficialStatsAsOf = "2026-07-27"
        model.tokenHeatmapOfficialGeneratedAt = Date(timeIntervalSince1970: 1_785_139_420)
        let codexWidget = try #require(model.makeWidgetSnapshot().provider(.codex))
        #expect(codexWidget.tokenSource == .thisMac)
        #expect(codexWidget.dailyTokens == [
            RunwayWidgetDailyTokens(date: "2026-07-26", tokens: 364),
        ])

        model.refreshTokenHeatmap(policy: .force)
        try await waitForTokenHeatmapRefresh(in: model)
        #expect(model.tokenHeatmapAllDevicesTokens == ["2026-07-26": 159])
        #expect(model.tokenHeatmapLocalTokens == ["2026-07-26": 364])
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

    @Test("refresh never mirrors another same-workspace user into the active managed credential")
    func refreshDoesNotOverwriteActiveSameWorkspaceUser() async throws {
        let firstAuth = Self.auth(
            accountId: "workspace-shared",
            userId: "user-one",
            email: "one@example.com")
        let secondAuth = Self.auth(
            accountId: "workspace-shared",
            userId: "user-two",
            email: "two@example.com")
        let store = isolatedAccountStore()
        let first = try store.upsert(auth: firstAuth, makeActive: true)
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in secondAuth },
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
                CodexProfileTokenUsage(dailyTokens: [:], statsAsOf: nil, generatedAt: nil)
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
        let model = RunwayModel(
            settings: settings,
            services: services,
            accountStore: store,
            quotaEstimateHistoryStore: isolatedHistoryStore())

        model.refreshQuota()
        try await waitForQuota(in: model)

        let stored = try store.loadCredential(id: first.id)
        #expect(CodexIdentityClaims.decode(stored.tokens.idToken)?.userId == "user-one")
        #expect(model.activeAccountId == first.id)
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
        let model = RunwayModel(
            settings: settings,
            services: services,
            accountStore: store,
            quotaEstimateHistoryStore: isolatedHistoryStore())

        model.refreshTokenHeatmap()
        try await profileService.waitUntilFirstRequest()
        model.switchAccount(id: secondAccount.id, restartCodex: false)
        try await waitForActiveAccount(secondAccount.id, in: store)
        await profileService.releaseFirstRequest()
        try await waitForAccountSwitch(secondAccount.id, in: model)

        #expect(model.tokenHeatmapAllDevicesTokens["2026-07-26"] == 200)
        #expect(!model.tokenHeatmapAllDevicesTokens.values.contains(100))
    }

    @Test("re-applying the listed current account overwrites drifted official auth")
    func reappliesListedCurrentAccountToOfficialAuth() async throws {
        let currentAuth = Self.auth(accountId: "acct-current")
        let driftedAuth = Self.auth(accountId: "acct-drifted")
        let store = isolatedAccountStore()
        let current = try store.upsert(auth: currentAuth, makeActive: true)
        try store.saveOfficialAuth(currentAuth)
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let services = RunwayModelServices(
            loadValidAuth: { _, cached in cached ?? currentAuth },
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
                CodexProfileTokenUsage(dailyTokens: [:], statsAsOf: nil, generatedAt: nil)
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
        let model = RunwayModel(
            settings: settings,
            services: services,
            accountStore: store,
            quotaEstimateHistoryStore: isolatedHistoryStore())
        try store.saveOfficialAuth(driftedAuth)

        #expect(model.activeAccountId == current.id)
        #expect(try store.loadOfficialAuth().tokens.accountId == "acct-drifted")

        model.switchAccount(id: current.id, restartCodex: false)
        try await waitForOfficialAccount("acct-current", in: store, model: model)

        #expect(model.activeAccountId == current.id)
        #expect(try store.loadOfficialAuth().tokens.accountId == "acct-current")
        #expect(!model.isSwitchingAccount)
    }

    @Test("full refresh starts independent popover sections without waiting for API cost")
    func fullRefreshStartsIndependentSectionsWithoutWaitingForAPICost() async throws {
        // Gate-based ordering (not sleep races): hold cost and reset so we can
        // prove independent sections start while cost is still in flight, and that
        // cost finishes without waiting for reset credits.
        let recorder = RefreshEventRecorder()
        let costHold = AsyncGate()
        let resetHold = AsyncGate()
        defer {
            costHold.release()
            resetHold.release()
        }
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateShowsCostSummary(true)
        settings.updateShowsSessionRepairSummary(true)
        settings.updateShowsRecentSessions(true)
        // Keep this test focused on cost/reset/session scheduling, not heatmap IO.
        settings.updateShowsTokenUsageHeatmap(false)

        let quota = Self.quotaSnapshot()
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in Self.auth() },
            fetchQuota: { _ in
                await recorder.record("quota-start")
                await recorder.record("quota-finish")
                return quota
            },
            fetchResetCredits: { _ in
                await recorder.record("reset-start")
                await resetHold.wait()
                await recorder.record("reset-finish")
                return ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date())
            },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, _, _ in
                await recorder.record("cost-start")
                await costHold.wait()
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

        try await recorder.waitFor("repair-start")
        try await recorder.waitFor("recent-start")
        try await recorder.waitFor("cost-start")
        try await recorder.waitFor("reset-start")

        // While cost is still held, independent popover sections must already have started.
        var events = recorder.events
        #expect(events.contains("repair-start"))
        #expect(events.contains("recent-start"))
        #expect(events.contains("cost-start"))
        #expect(!events.contains("cost-finish"))
        #expect(!events.contains("reset-finish"))
        #expect(events.filter { $0 == "quota-start" }.count == 1)

        costHold.release()
        try await recorder.waitFor("cost-finish")

        // Cost finished while reset credits are still held — must not serialize behind reset.
        events = recorder.events
        #expect(events.contains("cost-finish"))
        #expect(!events.contains("reset-finish"))

        resetHold.release()
        try await recorder.waitFor("reset-finish")
        events = recorder.events
        #expect(events.contains("reset-finish"))
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
        #expect(captured.queries.allSatisfy { $0.dayBoundary == .local })
        #expect(selected.window.end == captured.now)
        #expect(captured.policy == .force)
        try await waitForCostRefresh(in: model)
        #expect(recorder.captureCount == 1)
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

        #expect(recorder.captureCount == 1)
        #expect(!model.isRefreshing(.apiCost))

        model.refreshCost(policy: .force)
        _ = try await recorder.waitForBatch(count: 2)
        #expect(recorder.captureCount == 2)
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
        #expect(recorder.captureCount == 1)
    }

    @Test("current cycle detail refreshes a snapshot whose elapsed end is stale")
    func currentCycleDetailRefreshesStaleElapsedSnapshot() async throws {
        let recorder = CostBatchRecorder()
        let settings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        settings.updateApiCostSummaryRange(.current)
        let quota = Self.quotaSnapshot(secondaryReset: Date().addingTimeInterval(6 * 24 * 3_600))
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in Self.auth() },
            fetchQuota: { _ in quota },
            fetchResetCredits: { _ in ResetCreditsSnapshot(availableCount: 0, credits: [], updatedAt: Date()) },
            fetchRateLimitResetToday: {
                RateLimitResetTodaySnapshot(state: .no, fetchedAt: Date())
            },
            scanAPIEquivalent: { queries, now, policy, _ in
                await recorder.record(queries: queries, now: now, policy: policy)
                let isFirstScan = await recorder.captureCount == 1
                return Dictionary(uniqueKeysWithValues: queries.map { query in
                    let window = isFirstScan
                        ? DateInterval(
                            start: query.window.start,
                            end: query.window.end.addingTimeInterval(-3_600))
                        : query.window
                    return (query.id, Self.costSummary(window: window, calculatedAt: now))
                })
            },
            fetchDailyWorkspaceUsage: { _, _, _, window, now in
                Self.costSummary(window: window, calculatedAt: now)
            },
            fetchCodexProfileTokenUsage: { _ in CodexProfileTokenUsage(dailyTokens: [:]) },
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
        try await waitForCostRefresh(in: model)

        _ = try await model.queryCurrentCycleCost()

        #expect(recorder.captureCount == 2)
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
        #expect(recorder.captureCount == 1)
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
            Task { completionRecorder.record("complete") }
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

    @Test("model-specific quota usage is hidden until opted in")
    func modelSpecificQuotaUsageIsOptIn() async throws {
        let modelTitle = "GPT-5.3-Codex-Spark"
        let quota = Self.quotaSnapshot(additionalWindows: [
            NamedRateWindow(
                name: modelTitle,
                window: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 10_080,
                    resetsAt: Date(timeIntervalSince1970: 1_783_314_000))),
        ])

        let defaultSettings = RunwaySettings(store: PreferencesStore(defaults: scopedDefaults()))
        let defaultModel = makeModel(
            settings: defaultSettings,
            services: Self.costRangeServices(quota: quota, recorder: CostBatchRecorder()))
        defaultModel.refreshQuota()
        try await waitForQuota(in: defaultModel)

        #expect(defaultModel.quotaMeters.map(\.title) == [
            defaultSettings.l10n.text(.fiveHourUsage),
            defaultSettings.l10n.text(.weeklyUsage),
        ])
        #expect(defaultModel.quotaMeters.allSatisfy { $0.source == .standard })
        #expect(!defaultModel.quotaLines.contains { $0.title == modelTitle })

        let optedInDefaults = scopedDefaults()
        var optedInPreferences = RunwayPreferences()
        optedInPreferences.showsModelSpecificQuotaUsage = true
        PreferencesStore(defaults: optedInDefaults).save(optedInPreferences)
        let optedInSettings = RunwaySettings(store: PreferencesStore(defaults: optedInDefaults))
        let optedInModel = makeModel(
            settings: optedInSettings,
            services: Self.costRangeServices(quota: quota, recorder: CostBatchRecorder()))
        optedInModel.refreshQuota()
        try await waitForQuota(in: optedInModel)

        #expect(optedInModel.quotaMeters.contains {
            $0.title == modelTitle && $0.source == .modelSpecific
        })
        #expect(optedInModel.quotaLines.contains { $0.title == modelTitle })

        optedInSettings.updateShowsModelSpecificQuotaUsage(false)
        optedInModel.relabel()
        #expect(!optedInModel.quotaMeters.contains { $0.title == modelTitle })

        optedInSettings.updateShowsModelSpecificQuotaUsage(true)
        optedInModel.relabel()
        #expect(optedInModel.quotaMeters.contains {
            $0.title == modelTitle && $0.source == .modelSpecific
        })
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
        RunwayModel(
            settings: settings,
            services: services,
            accountStore: isolatedAccountStore(),
            quotaEstimateHistoryStore: isolatedHistoryStore())
    }

    private func isolatedHistoryStore() -> QuotaEstimateHistoryStore {
        QuotaEstimateHistoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("quota-estimate-history-\(UUID().uuidString).json"))
    }

    private func waitForQuotaEstimate(in model: RunwayModel) async throws {
        for _ in 0..<100 {
            if model.quotaEstimate != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for quota estimate")
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

    private func waitForOfficialAccount(
        _ accountId: String,
        in store: AccountStore,
        model: RunwayModel) async throws
    {
        // switchTo writes official auth before the switch Task finishes other work.
        for _ in 0..<200 {
            if (try? store.loadOfficialAuth())?.tokens.accountId == accountId,
               !model.isSwitchingAccount
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for official auth rewrite")
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

    private func waitForFullRefresh(in model: RunwayModel) async throws {
        for _ in 0..<100 {
            if !model.isRefreshingAll { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for full refresh")
    }

    private func waitForTokenHeatmapRefresh(in model: RunwayModel) async throws {
        for _ in 0..<100 {
            if !model.isRefreshing(.tokenHeatmap) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for token heatmap refresh")
    }

    nonisolated private static func quotaSnapshot(
        primaryMinutes: Int = 300,
        secondaryReset: Date? = nil,
        additionalWindows: [NamedRateWindow] = []) -> QuotaSnapshot
    {
        let now = Date(timeIntervalSince1970: 1_782_710_000)
        return QuotaSnapshot(
            plan: "pro",
            primary: RateWindow(usedPercent: 20, windowMinutes: primaryMinutes, resetsAt: now.addingTimeInterval(3_600)),
            secondary: RateWindow(usedPercent: 30, windowMinutes: 10_080, resetsAt: secondaryReset ?? now.addingTimeInterval(10_080 * 60)),
            additionalWindows: additionalWindows,
            creditsBalance: nil,
            updatedAt: now)
    }

    nonisolated private static func auth(
        accountId: String = "acct-test",
        userId: String? = nil,
        email: String = "test@example.com") -> CodexAuth
    {
        // Long JWT + refresh so loginUsability stays .usable (must never mirror into real ~/.codex).
        var authClaims: [String: Any] = [
            "chatgpt_account_id": accountId,
            "chatgpt_plan_type": "pro",
        ]
        if let userId {
            authClaims["chatgpt_user_id"] = userId
        }
        let access = jwt(payload: [
            "exp": 4_100_000_000,
            "email": email,
            "https://api.openai.com/auth": authClaims,
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

    nonisolated private static func estimateSummary(
        window: DateInterval,
        calculatedAt: Date
    ) -> ApiEquivalentSummary {
        let day = QuotaEstimateCalculator.utcDay(calculatedAt)
        let totals = ApiEquivalentTotals(
            totalTokens: 12_000,
            uncachedInputTokens: 8_000,
            cachedInputTokens: 2_000,
            outputTokens: 2_000,
            turns: 4,
            threads: 1)
        return ApiEquivalentSummary(
            source: .onlineAnalytics,
            confidence: .priced,
            window: window,
            estimatedUSD: 0.5,
            totals: totals,
            dailyRows: [
                ApiEquivalentDailyRow(
                    date: day,
                    totals: totals,
                    estimatedUSD: 0.5,
                    rawCredits: 30),
            ],
            modelRows: [],
            clientRows: [],
            rawCredits: 30,
            warnings: [],
            pricingVersion: "test",
            calculatedAt: calculatedAt)
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

    nonisolated private static func localHeatmapSummary(
        window: DateInterval,
        calculatedAt: Date
    ) -> ApiEquivalentSummary {
        let totals = ApiEquivalentTotals(
            totalTokens: 364,
            uncachedInputTokens: 300,
            cachedInputTokens: 0,
            outputTokens: 64,
            turns: 1,
            threads: 1)
        return ApiEquivalentSummary(
            source: .localSessions,
            confidence: .priced,
            window: window,
            estimatedUSD: 0.01,
            totals: totals,
            dailyRows: [
                ApiEquivalentDailyRow(
                    date: "2026-07-26",
                    totals: totals,
                    estimatedUSD: 0.01,
                    rawCredits: 0),
            ],
            modelRows: [],
            clientRows: [],
            rawCredits: 0,
            warnings: [],
            pricingVersion: "test",
            calculatedAt: calculatedAt)
    }
}

private struct CostBatchCapture: Sendable {
    let queries: [ApiCostQuery]
    let now: Date
    let policy: UsageCostRefreshPolicy
}

@MainActor
private final class CostBatchRecorder {
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

private actor CallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

@MainActor
private final class RefreshEventRecorder {
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

/// Synchronous-release gate for deterministic concurrency tests (safe in `defer`).
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        // Register under the lock only inside the sync continuation setup so this
        // stays valid under Swift 6's "no locks across async" rule.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
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

private actor FailOnceProfileUsageService {
    private var attempts = 0

    func fetch() throws -> CodexProfileTokenUsage {
        attempts += 1
        if attempts == 1 {
            throw URLError(.timedOut)
        }
        return CodexProfileTokenUsage(dailyTokens: ["2026-07-26": 159])
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
        for _ in 0..<300 {
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
