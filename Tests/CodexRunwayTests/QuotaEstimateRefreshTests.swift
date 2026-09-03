import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Quota estimate refresh")
@MainActor
struct QuotaEstimateRefreshTests {
    @Test("reported zero credits with substantial usage remain unavailable without history")
    func zeroCreditsWithUsageDoesNotCreateEstimate() async throws {
        let fixture = QuotaEstimateRefreshFixture()
        fixture.credits = 0
        let model = fixture.makeModel()

        model.refreshQuotaEstimate()
        try await waitUntil { model.quotaEstimate != nil }

        let snapshot = try #require(model.quotaEstimate)
        #expect(snapshot.usedPercent == 47)
        #expect(snapshot.currentRows.reduce(0) { $0 + $1.tokens } == 694_950_000)
        #expect(snapshot.unavailableReason == .zeroCreditsWithUsage)
        #expect(!snapshot.canExtrapolate)
        #expect(snapshot.estimatedCredits == nil)
        #expect(snapshot.estimatedUSD == nil)
        #expect(model.quotaEstimateError == nil)
        #expect(fixture.history.load(accountKey: fixture.accountKey).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.history.fileURL.path))
    }

    @Test("failed refresh preserves the last snapshot and mode changes preserve its timestamp")
    func failureAndRelabelKeepLastSuccessfulTimestamp() async throws {
        let fixture = QuotaEstimateRefreshFixture()
        let model = fixture.makeModel()
        model.refreshQuotaEstimate()
        try await waitUntil { model.quotaEstimate != nil }
        let snapshot = try #require(model.quotaEstimate)
        let historyData = try Data(contentsOf: fixture.history.fileURL)
        #expect(snapshot.calculatedAt == QuotaEstimateRefreshFixture.calculatedAt)
        #expect(fixture.history.load(accountKey: fixture.accountKey).count == 1)

        fixture.shouldFail = true
        model.refreshQuotaEstimate()
        try await waitUntil { model.quotaEstimateError != nil }

        #expect(model.quotaEstimate == snapshot)
        #expect(model.quotaEstimateError == URLError(.notConnectedToInternet).localizedDescription)
        #expect(try Data(contentsOf: fixture.history.fileURL) == historyData)
        model.settings.updateQuotaEstimateWindowMode(.rollingWeek)
        model.relabel()
        #expect(model.quotaEstimate?.windowMode == .rollingWeek)
        #expect(model.quotaEstimate?.calculatedAt == snapshot.calculatedAt)
        #expect(model.quotaEstimateError != nil)
        #expect(try Data(contentsOf: fixture.history.fileURL) == historyData)
    }

    @Test("old account generations cannot publish a late result or error", arguments: [false, true])
    func lateResponseAfterAccountChangesIsDiscarded(fails: Bool) async throws {
        let fixture = QuotaEstimateRefreshFixture()
        fixture.blocksUsage = true
        let model = fixture.makeModel()
        let firstKey = fixture.accountKey
        defer { fixture.releaseUsage() }
        model.refreshQuotaEstimate()
        try await waitUntil { fixture.isUsagePending }

        fixture.auth = QuotaEstimateRefreshFixture.auth(accountID: "account-b")
        let secondKey = fixture.accountKey
        model.refreshQuota()
        try await waitUntil {
            fixture.quotaAccountIDs.last == "account-b" && !model.isRefreshing(.quota)
        }
        // Return to A so matching identity alone cannot accept its old request.
        fixture.auth = QuotaEstimateRefreshFixture.auth(accountID: "account-a")
        model.refreshQuota()
        try await waitUntil {
            fixture.quotaAccountIDs.count == 3 && !model.isRefreshing(.quota)
        }
        fixture.shouldFail = fails
        fixture.releaseUsage()
        try await waitUntil { !model.isRefreshing(.quotaEstimate) }

        #expect(model.quotaEstimate == nil)
        #expect(model.quotaEstimateError == nil)
        #expect(fixture.history.load(accountKey: firstKey).isEmpty)
        #expect(fixture.history.load(accountKey: secondKey).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.history.fileURL.path))
    }

    @Test("a late initial quota response cannot replace the current account generation", arguments: [false, true])
    func lateInitialQuotaResponseIsDiscarded(fails: Bool) async throws {
        let fixture = QuotaEstimateRefreshFixture()
        fixture.blocksFirstQuota = true
        let model = fixture.makeModel()
        defer { fixture.releaseFirstQuota() }
        let firstRequest = Task { await model.refreshQuotaEstimateNow() }
        try await waitUntil { fixture.isFirstQuotaPending }

        fixture.auth = QuotaEstimateRefreshFixture.auth(accountID: "account-b")
        model.refreshQuota()
        try await waitUntil {
            fixture.quotaAccountIDs.last == "account-b" && model.quotaEstimate != nil
                && model.refreshingSections.isEmpty
        }
        fixture.auth = QuotaEstimateRefreshFixture.auth(accountID: "account-a")
        model.refreshQuota()
        try await waitUntil {
            fixture.quotaAccountIDs.count == 3 && model.quotaEstimate != nil
                && model.refreshingSections.isEmpty
        }
        let snapshot = try #require(model.quotaEstimate)
        let quotaText = model.quotaText
        let historyData = try Data(contentsOf: fixture.history.fileURL)
        fixture.firstQuotaFails = fails
        fixture.releaseFirstQuota()
        await firstRequest.value

        #expect(model.quotaEstimate == snapshot)
        #expect(model.quotaText == quotaText)
        #expect(model.quotaEstimateError == nil)
        #expect(fixture.usageFetchCount == 2)
        #expect(try Data(contentsOf: fixture.history.fileURL) == historyData)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Timed out waiting for quota estimate refresh")
    }
}

@MainActor
private final class QuotaEstimateRefreshFixture {
    static let calculatedAt = Date(timeIntervalSince1970: 1_788_393_600)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-runway-estimate-refresh-\(UUID().uuidString)", isDirectory: true)
    var auth = QuotaEstimateRefreshFixture.auth(accountID: "account-a")
    var credits: Double = 47
    var shouldFail = false
    var blocksUsage = false
    var blocksFirstQuota = false
    var firstQuotaFails = false
    private(set) var quotaAccountIDs: [String] = []
    private(set) var usageFetchCount = 0
    private var usageContinuation: CheckedContinuation<Void, Never>?
    private var quotaContinuation: CheckedContinuation<Void, Never>?

    var isUsagePending: Bool { usageContinuation != nil }
    var isFirstQuotaPending: Bool { quotaContinuation != nil }
    var accountKey: String { AccountIdentity.matchKey(for: auth) }
    var history: QuotaEstimateHistoryStore {
        QuotaEstimateHistoryStore(fileURL: root.appendingPathComponent("history.json"))
    }

    func makeModel() -> RunwayModel {
        let suite = "CodexRunwayQuotaEstimateRefresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = RunwaySettings(store: PreferencesStore(defaults: defaults))
        settings.updateShowsQuotaEstimateSummary(true)
        settings.updateShowsRateLimitResetToday(false)
        settings.updateQuotaAlertsEnabled(false)
        settings.updateResetCreditAlertsEnabled(false)
        settings.updateExportsStatusJSON(false)
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in await self.auth },
            fetchQuota: { auth in try await self.fetchQuota(auth) },
            fetchResetCredits: { _ in throw URLError(.unsupportedURL) },
            fetchRateLimitResetToday: { throw URLError(.unsupportedURL) },
            scanAPIEquivalent: { _, _, _, _ in throw URLError(.unsupportedURL) },
            fetchDailyWorkspaceUsage: { _, _, _, window, _ in
                try await self.fetchUsage(window: window)
            },
            fetchCodexProfileTokenUsage: { _ in throw URLError(.unsupportedURL) },
            dryRunSessions: { throw URLError(.unsupportedURL) },
            scanRecentSessions: { _ in throw URLError(.unsupportedURL) })
        return RunwayModel(
            settings: settings,
            services: services,
            accountStore: AccountStore(
                rootURL: root.appendingPathComponent("accounts", isDirectory: true),
                officialAuthURL: root.appendingPathComponent("auth.json")),
            costCacheStore: UsageCostCacheStore(cacheURL: root.appendingPathComponent("cost.json")),
            quotaEstimateHistoryStore: history,
            grokCLIAvailable: false)
    }

    private func fetchQuota(_ auth: CodexAuth) async throws -> QuotaSnapshot {
        quotaAccountIDs.append(auth.tokens.accountId ?? "")
        let isBlockedFirstRequest = blocksFirstQuota && quotaAccountIDs.count == 1
        if isBlockedFirstRequest {
            await withCheckedContinuation { quotaContinuation = $0 }
            if firstQuotaFails { throw URLError(.notConnectedToInternet) }
        }
        return QuotaSnapshot(
            plan: "pro",
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: Self.calculatedAt),
            secondary: RateWindow(
                usedPercent: isBlockedFirstRequest ? 19 : 47,
                windowMinutes: 10_080,
                resetsAt: Self.calculatedAt.addingTimeInterval(4 * 86_400)),
            additionalWindows: [],
            creditsBalance: nil,
            updatedAt: Self.calculatedAt)
    }

    private func fetchUsage(window: DateInterval) async throws -> ApiEquivalentSummary {
        usageFetchCount += 1
        let credits = credits
        if blocksUsage {
            await withCheckedContinuation { usageContinuation = $0 }
        }
        if shouldFail { throw URLError(.notConnectedToInternet) }
        let totals = ApiEquivalentTotals(
            totalTokens: 694_950_000,
            uncachedInputTokens: 600_000_000,
            cachedInputTokens: 90_000_000,
            outputTokens: 4_950_000,
            turns: 10,
            threads: 1)
        return ApiEquivalentSummary(
            source: .onlineAnalytics,
            confidence: .tokensOnly,
            window: window,
            estimatedUSD: nil,
            totals: totals,
            dailyRows: [ApiEquivalentDailyRow(
                date: "2026-09-02",
                totals: totals,
                estimatedUSD: nil,
                rawCredits: credits,
                creditsReported: true,
                totalsReported: true)],
            modelRows: [],
            clientRows: [],
            rawCredits: credits,
            warnings: [],
            pricingVersion: "test",
            calculatedAt: Self.calculatedAt)
    }

    func releaseUsage() {
        usageContinuation?.resume()
        usageContinuation = nil
    }

    func releaseFirstQuota() {
        quotaContinuation?.resume()
        quotaContinuation = nil
    }

    static func auth(accountID: String) -> CodexAuth {
        CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: "test-id-\(accountID)",
                accessToken: "test-access-\(accountID)",
                refreshToken: "test-refresh-\(accountID)",
                accountId: accountID),
            lastRefresh: nil)
    }
}
