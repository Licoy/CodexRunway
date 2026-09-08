import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Current account authentication state")
@MainActor
struct RunwayAuthenticationStateTests {
    @Test("successful quota followed by 401 clears panel, tick and exported widget", arguments: [false, true])
    func revokedQuotaClearsEveryDisplay(fullRefresh: Bool) async throws {
        let fixture = StateFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.refresh()
        try await wait { !model.isRefreshingAll }
        #expect(!model.quotaMeters.isEmpty)
        #expect(model.resetCreditSummary != nil)
        #expect(model.makeWidgetSnapshot().provider(.codex)?.availability == .available)

        await fixture.responses.failQuota(.userAuthenticationRequired)
        if fullRefresh { model.refresh() } else { model.refreshQuota() }
        try await wait { !model.isRefreshing && model.lastError != nil }
        model.tick(now: Date().addingTimeInterval(60))
        model.relabel()

        try expectLoggedOut(model)
        let data = try JSONEncoder().encode(model.makeWidgetSnapshot())
        let exported = try JSONDecoder().decode(RunwayWidgetSnapshot.self, from: data)
        let codex = try #require(exported.provider(.codex))
        #expect(codex.availability == .notLoggedIn)
        #expect(codex.quota.isEmpty)
        #expect(codex.balanceUSD == nil)
        #expect(codex.resetCredits == nil)

        await fixture.responses.failQuota(nil)
        model.refreshQuota()
        try await wait { !model.isRefreshing && !model.quotaMeters.isEmpty }
        #expect(model.lastError == nil)
        #expect(model.makeWidgetSnapshot().provider(.codex)?.availability == .available)
    }

    @Test("temporary quota failures preserve the last available quota", arguments: [URLError.Code.timedOut, .badServerResponse])
    func temporaryFailuresKeepQuota(code: URLError.Code) async throws {
        let fixture = StateFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.refreshQuota()
        try await wait { !model.isRefreshing && !model.quotaMeters.isEmpty }
        let before = model.quotaMeters
        await fixture.responses.failQuota(code)
        model.refreshQuota()
        try await wait { !model.isRefreshing && model.lastError != nil }
        model.tick()
        #expect(model.quotaMeters == before)
        #expect(model.accountDisplay.isAuthenticated)
        #expect(model.makeWidgetSnapshot().provider(.codex)?.availability == .available)
    }

    @Test("late reset-credit success cannot restore data after quota authorization fails")
    func lateCreditsDoNotRestoreInvalidatedState() async throws {
        let fixture = StateFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.refresh()
        try await wait { !model.isRefreshingAll }
        #expect(model.resetCreditSummary != nil)
        await fixture.responses.holdCreditsAndRejectQuota()
        model.refresh()
        try await wait { model.lastError != nil && model.quotaMeters.isEmpty }
        await fixture.responses.releaseCredits()
        try await wait { !model.isRefreshingAll }
        model.tick()
        try expectLoggedOut(model)
        #expect(model.makeWidgetSnapshot().provider(.codex)?.resetCredits == nil)
    }

    @Test("refresh-token authentication failure also clears previously available quota")
    func rejectedAuthLoadClearsQuota() async throws {
        let fixture = StateFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.refreshQuota()
        try await wait { !model.isRefreshing && !model.quotaMeters.isEmpty }
        await fixture.responses.rejectAuthLoad()
        model.refreshQuota()
        try await wait { !model.isRefreshing && model.lastError != nil }
        model.tick()
        try expectLoggedOut(model)
    }

    @Test("cost and reset-credit refresh failures invalidate current quota too", arguments: [false, true])
    func secondaryRefreshInvalidatesQuota(resetCredits: Bool) async throws {
        let fixture = StateFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.refresh()
        try await wait { !model.isRefreshingAll }
        #expect(!model.quotaMeters.isEmpty)
        if resetCredits {
            await fixture.responses.rejectCredits()
            model.refreshResetCredits()
        } else {
            await fixture.responses.failQuota(.userAuthenticationRequired)
            model.refreshCost()
        }
        try await wait { !model.isRefreshing && model.lastError != nil }
        model.tick()
        try expectLoggedOut(model)
    }

    @Test("full refresh keeps the reauthorization message when quota-estimate auth fails")
    func quotaEstimateFailureRemainsVisible() async throws {
        let fixture = StateFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.refresh()
        try await wait { !model.isRefreshingAll }
        #expect(!model.quotaMeters.isEmpty)
        model.settings.updateShowsQuotaEstimateSummary(true)
        await fixture.responses.rejectAnalytics()
        model.refresh()
        try await wait { !model.isRefreshingAll }
        #expect(model.lastError != nil)
        model.tick()
        try expectLoggedOut(model)
    }

    @Test("late profile failure preserves the reauthorization message from reset credits")
    func lateProfileFailureKeepsAuthenticationError() async throws {
        let fixture = StateFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.refresh()
        try await wait { !model.isRefreshingAll }
        model.settings.updateShowsTokenUsageHeatmap(true)
        await fixture.responses.holdProfileAndRejectCredits()
        model.refresh()
        try await wait { !model.accountDisplay.isAuthenticated && model.lastError != nil }
        let authenticationError = model.lastError
        await fixture.responses.releaseProfile()
        try await wait { !model.isRefreshingAll }
        #expect(model.lastError == authenticationError)
        #expect(model.tokenHeatmapCalculatedAt == nil)
        try expectLoggedOut(model)
    }

    private func expectLoggedOut(_ model: RunwayModel) throws {
        #expect(model.quotaMeters.isEmpty)
        #expect(model.quotaLines.isEmpty)
        #expect(model.resetCreditSummary == nil)
        #expect(model.resetCreditDetails.isEmpty)
        #expect(!model.accountDisplay.isAuthenticated)
        #expect(model.statusText == model.l10n.text(.statusLogin))
        let codex = try #require(model.makeWidgetSnapshot().provider(.codex))
        #expect(codex.availability == .notLoggedIn)
        #expect(codex.quota.isEmpty)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for account display state")
    }
}

@MainActor
private struct StateFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("auth-display-\(UUID().uuidString)")
    let suiteName = "auth-display-\(UUID().uuidString)"
    let responses = AuthenticationResponses()
    let model: RunwayModel

    init() {
        let settings = RunwaySettings(store: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!))
        settings.updateShowsQuotaEstimateSummary(false)
        settings.updateShowsCostSummary(false)
        settings.updateShowsRecentSessions(false)
        settings.updateShowsSessionRepairSummary(false)
        settings.updateShowsTokenUsageHeatmap(false)
        settings.updateShowsRateLimitResetToday(false)
        let responses = responses
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in try await responses.auth() },
            fetchQuota: { _ in try await responses.quota() },
            fetchResetCredits: { _ in try await responses.credits() },
            fetchRateLimitResetToday: { throw URLError(.unsupportedURL) },
            scanAPIEquivalent: { _, _, _, _ in throw URLError(.unsupportedURL) },
            fetchDailyWorkspaceUsage: { _, _, _, _, _ in try await responses.analytics() },
            fetchCodexProfileTokenUsage: { _ in try await responses.profile() },
            dryRunSessions: { throw URLError(.unsupportedURL) },
            scanRecentSessions: { _ in SessionActivitySummary(items: []) })
        model = RunwayModel(
            settings: settings, services: services,
            accountStore: AccountStore(rootURL: root.appendingPathComponent("accounts"), officialAuthURL: root.appendingPathComponent("auth.json")),
            costCacheStore: UsageCostCacheStore(cacheURL: root.appendingPathComponent("cost.json")),
            quotaEstimateHistoryStore: QuotaEstimateHistoryStore(fileURL: root.appendingPathComponent("history.json")))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

private actor AuthenticationResponses {
    private var quotaFailure: URLError.Code?
    private var authFailure = false
    private var creditsFailure = false
    private var analyticsFailure = false
    private var holdsCredits = false
    private var creditsStarted = false
    private var creditsContinuation: CheckedContinuation<Void, Never>?
    private var holdsProfile = false
    private var profileContinuation: CheckedContinuation<Void, Never>?

    func failQuota(_ code: URLError.Code?) { quotaFailure = code }
    func rejectAuthLoad() { authFailure = true }
    func rejectCredits() { creditsFailure = true }
    func rejectAnalytics() { analyticsFailure = true }
    func holdCreditsAndRejectQuota() { holdsCredits = true; quotaFailure = .userAuthenticationRequired }
    func releaseCredits() { holdsCredits = false; creditsContinuation?.resume(); creditsContinuation = nil }
    func holdProfileAndRejectCredits() { holdsProfile = true }
    func releaseProfile() { profileContinuation?.resume(); profileContinuation = nil }

    func profile() async throws -> CodexProfileTokenUsage {
        guard holdsProfile else { throw URLError(.unsupportedURL) }
        await withCheckedContinuation { profileContinuation = $0 }
        throw URLError(.timedOut)
    }

    func auth() throws -> CodexAuth {
        if authFailure { throw URLError(.userAuthenticationRequired) }
        let payload: [String: Any] = ["exp": 4_100_000_000, "email": "state@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "state-test"]]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let token = [Data(#"{"alg":"none"}"#.utf8), body, Data()]
            .map { $0.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
            .joined(separator: ".")
        return CodexAuth(authMode: "chatgpt", tokens: .init(idToken: token, accessToken: token, refreshToken: "state-test-refresh-token-not-for-production", accountId: "state-test"), lastRefresh: nil)
    }

    func quota() async throws -> QuotaSnapshot {
        while holdsCredits && !creditsStarted { await Task.yield() }
        if let quotaFailure { throw URLError(quotaFailure) }
        return QuotaSnapshot(plan: "plus", primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: Date().addingTimeInterval(3600)), secondary: nil, additionalWindows: [], creditsBalance: 10, updatedAt: Date())
    }

    func credits() async throws -> ResetCreditsSnapshot {
        if holdsProfile {
            while profileContinuation == nil { await Task.yield() }
            throw URLError(.userAuthenticationRequired)
        }
        if creditsFailure { throw URLError(.userAuthenticationRequired) }
        if holdsCredits {
            creditsStarted = true
            await withCheckedContinuation { creditsContinuation = $0 }
        }
        return ResetCreditsSnapshot(availableCount: 2, credits: [], updatedAt: Date())
    }

    func analytics() throws -> ApiEquivalentSummary {
        throw URLError(analyticsFailure ? .userAuthenticationRequired : .unsupportedURL)
    }
}
