import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Account invalidation and stale responses", .serialized)
@MainActor
struct RunwayAccountInvalidationTests {
    @Test("late auth responses for A cannot replace the newly selected B", arguments: [false, true])
    func lateAuthResponseAfterSwitch(fails: Bool) async throws {
        let fixture = try AccountInvalidationFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.refreshQuota()
        try await wait { !model.isRefreshing && !model.quotaMeters.isEmpty }

        await fixture.gate.holdNextAuth(failing: fails)
        model.refreshResetCredits()
        try await wait { await fixture.gate.authIsHeld }
        await fixture.gate.selectAuth(fixture.authB)
        model.switchAccount(id: fixture.accountB.id, restartCodex: false)
        try await wait { !model.isSwitchingAccount && model.activeAccountId == fixture.accountB.id }
        model.refreshQuota()
        try await wait { !model.isRefreshing(.quota) && !model.quotaMeters.isEmpty }
        #expect(model.accountDisplay.isAuthenticated)
        #expect(try fixture.store.loadOfficialAuth().tokens.accountId == "review-b")

        await fixture.gate.releaseAuth()
        try await wait { !model.isRefreshing }
        #expect(model.activeAccountId == fixture.accountB.id)
        #expect(model.accountDisplay.isAuthenticated)
        #expect(model.accountDisplay.accountId == "review-b")
        #expect(!model.quotaMeters.isEmpty)
        #expect(model.makeWidgetSnapshot().provider(.codex)?.availability == .available)
    }

    @Test("late cost scan cannot restore cost or hide authentication errors", arguments: [false, true])
    func lateCostAfterAuthenticationFailure(scanFails: Bool) async throws {
        let fixture = try AccountInvalidationFixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.refreshQuota()
        try await wait { !model.isRefreshing && !model.quotaMeters.isEmpty }
        await fixture.gate.setCostFailure(scanFails)
        model.refreshCost()
        try await wait { await fixture.gate.costIsHeld }
        await fixture.gate.rejectQuota()
        model.refreshQuota()
        try await wait { !model.isRefreshing(.quota) && model.lastError != nil && model.quotaMeters.isEmpty }
        #expect(!model.accountDisplay.isAuthenticated)
        #expect(model.costDetail == nil)

        await fixture.gate.releaseCost()
        try await wait { !model.isRefreshing }
        #expect(model.costDetail == nil, "Late cost scan republished data after authentication failure")
        #expect(model.makeWidgetSnapshot().provider(.codex)?.apiEquivalentCostUSD == nil)
        #expect(model.lastError != nil, "Late cost scan erased the reauthorization error")
    }

    @Test("account-list authentication failures affect only the current display", arguments: AccountRefreshRoute.allCases)
    func accountListRefreshInvalidatesCurrentDisplay(route: AccountRefreshRoute) async throws {
        let fixture = try AccountInvalidationFixture()
        defer { fixture.remove() }
        let model = fixture.model
        if route != .otherAccount {
            try fixture.store.deleteAccount(id: fixture.accountB.id)
            model.reloadAccountIndex()
        }
        model.refreshQuota()
        try await wait { !model.isRefreshing && !model.quotaMeters.isEmpty }
        let currentID = try #require(model.activeAccountId)
        let context = try RunwayNetworkContext(sessionFactory: { configuration, delegate in
            configuration.protocolClasses = [AccountInvalidationURLProtocol.self]
            return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        })
        try await RunwayNetwork.$scopedContext.withValue(context) {
            switch route {
            case .currentAccount: model.refreshAccountQuota(id: currentID)
            case .otherAccount: model.refreshAccountQuota(id: fixture.accountB.id)
            case .allAccounts: model.refreshAllAccountQuotas()
            case .fullRefresh: model.refresh()
            }
            let refreshedID = route == .otherAccount ? fixture.accountB.id : currentID
            try await wait {
                !model.isRefreshingAll && !model.isRefreshingAccountQuota(id: refreshedID)
                    && model.managedAccounts.first(where: { $0.id == refreshedID })?.requiresReauth == true
            }
        }
        model.tick()
        if route == .otherAccount {
            #expect(model.accountDisplay.isAuthenticated)
            #expect(!model.quotaMeters.isEmpty)
            #expect(model.makeWidgetSnapshot().provider(.codex)?.availability == .available)
        } else {
            #expect(model.quotaMeters.isEmpty)
            #expect(!model.accountDisplay.isAuthenticated)
            #expect(model.makeWidgetSnapshot().provider(.codex)?.availability == .notLoggedIn)
        }
    }

    @Test("full refresh completes current-auth metadata before polling managed accounts", arguments: [false, true])
    func fullRefreshOrdersAuthBeforeAccountPolling(authFails: Bool) async throws {
        let fixture = try AccountInvalidationFixture()
        defer { fixture.remove() }
        let model = fixture.model
        try fixture.store.deleteAccount(id: fixture.accountB.id)
        model.reloadAccountIndex()
        model.refreshQuota()
        try await wait { !model.isRefreshing && !model.quotaMeters.isEmpty }
        await fixture.gate.holdNextAuth(failing: authFails)
        let context = try RunwayNetworkContext(sessionFactory: { configuration, delegate in
            configuration.protocolClasses = [AccountInvalidationURLProtocol.self]
            return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        })
        try await RunwayNetwork.$scopedContext.withValue(context) {
            model.refresh()
            try await wait { await fixture.gate.authIsHeld }
            #expect(!model.isRefreshingAccountQuotas)
            #expect(model.accountDisplay.isAuthenticated)
            await fixture.gate.releaseAuth()
            try await wait {
                !model.isRefreshingAll && !model.isRefreshingAccountQuotas
                    && model.managedAccounts.first?.requiresReauth == true
            }
        }
        #expect(!model.accountDisplay.isAuthenticated)
        #expect(model.quotaMeters.isEmpty)
    }

    enum AccountRefreshRoute: CaseIterable {
        case currentAccount, otherAccount, allAccounts, fullRefresh
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AccountInvalidationTimeout()
    }
}

private struct AccountInvalidationTimeout: Error {}

private final class AccountInvalidationURLProtocol: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private struct AccountInvalidationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-invalidation-\(UUID().uuidString)")
    let suiteName = "account-invalidation-\(UUID().uuidString)"
    let store: AccountStore
    let authB: CodexAuth
    let accountB: ManagedAccount
    let gate: AccountInvalidationResponses
    let model: RunwayModel

    init() throws {
        store = AccountStore(rootURL: root.appendingPathComponent("accounts"), officialAuthURL: root.appendingPathComponent("auth.json"))
        let authA = try Self.auth("review-a")
        authB = try Self.auth("review-b")
        _ = try store.upsert(auth: authA, makeActive: true)
        accountB = try store.upsert(auth: authB)
        try store.saveOfficialAuth(authA)
        gate = AccountInvalidationResponses(auth: authA)
        let gate = gate
        let settings = RunwaySettings(store: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!))
        settings.updateShowsQuotaEstimateSummary(false)
        settings.updateShowsCostSummary(false)
        settings.updateShowsRecentSessions(false)
        settings.updateShowsSessionRepairSummary(false)
        settings.updateShowsTokenUsageHeatmap(false)
        settings.updateShowsRateLimitResetToday(false)
        let services = RunwayModelServices(
            loadValidAuth: { _, _ in try await gate.loadAuth() },
            fetchQuota: { _ in try await gate.quota() },
            fetchResetCredits: { _ in ResetCreditsSnapshot(availableCount: 2, credits: [], updatedAt: Date()) },
            fetchRateLimitResetToday: { throw URLError(.unsupportedURL) },
            scanAPIEquivalent: { queries, now, _, _ in try await gate.scan(queries: queries, now: now) },
            fetchDailyWorkspaceUsage: { _, _, _, _, _ in throw URLError(.unsupportedURL) },
            fetchCodexProfileTokenUsage: { _ in throw URLError(.unsupportedURL) },
            dryRunSessions: { throw URLError(.unsupportedURL) },
            scanRecentSessions: { _ in SessionActivitySummary(items: []) })
        model = RunwayModel(
            settings: settings, services: services, accountStore: store,
            costCacheStore: UsageCostCacheStore(cacheURL: root.appendingPathComponent("cost.json")),
            quotaEstimateHistoryStore: QuotaEstimateHistoryStore(fileURL: root.appendingPathComponent("history.json")),
            grokCLIAvailable: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private static func auth(_ id: String) throws -> CodexAuth {
        let payload: [String: Any] = ["exp": 4_100_000_000, "email": "\(id)@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": id]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let token = [Data(#"{"alg":"none"}"#.utf8), data, Data()]
            .map { $0.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
            .joined(separator: ".")
        return CodexAuth(authMode: "chatgpt", tokens: .init(idToken: token, accessToken: token,
            refreshToken: "review-only-dummy-refresh-token-\(id)", accountId: id), lastRefresh: nil)
    }
}

private actor AccountInvalidationResponses {
    private var auth: CodexAuth
    private var holdsNextAuth = false
    private var heldAuthFails = false
    private var costFails = false
    private var authContinuation: CheckedContinuation<Void, Never>?
    private var costContinuation: CheckedContinuation<Void, Never>?
    private var rejectsQuota = false
    var authIsHeld: Bool { authContinuation != nil }
    var costIsHeld: Bool { costContinuation != nil }

    init(auth: CodexAuth) { self.auth = auth }
    func holdNextAuth(failing: Bool) { holdsNextAuth = true; heldAuthFails = failing }
    func setCostFailure(_ failing: Bool) { costFails = failing }
    func selectAuth(_ auth: CodexAuth) { self.auth = auth }
    func rejectQuota() { rejectsQuota = true }
    func releaseAuth() { authContinuation?.resume(); authContinuation = nil }
    func releaseCost() { costContinuation?.resume(); costContinuation = nil }

    func loadAuth() async throws -> CodexAuth {
        if holdsNextAuth {
            holdsNextAuth = false
            let requestedAuth = auth
            await withCheckedContinuation { authContinuation = $0 }
            if heldAuthFails { throw URLError(.userAuthenticationRequired) }
            return requestedAuth
        }
        return auth
    }

    func quota() throws -> QuotaSnapshot {
        if rejectsQuota { throw URLError(.userAuthenticationRequired) }
        return QuotaSnapshot(plan: "plus",
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: Date().addingTimeInterval(3600)),
            secondary: nil, additionalWindows: [], creditsBalance: 10, updatedAt: Date())
    }

    func scan(queries: [ApiCostQuery], now: Date) async throws -> [String: ApiEquivalentSummary] {
        await withCheckedContinuation { costContinuation = $0 }
        if costFails { throw URLError(.badServerResponse) }
        return Dictionary(uniqueKeysWithValues: queries.map { query in
            (query.id, ApiEquivalentSummary(source: .localSessions, confidence: .priced, window: query.window,
                estimatedUSD: 1, totals: ApiEquivalentTotals(totalTokens: 10, uncachedInputTokens: 5,
                    cachedInputTokens: 2, outputTokens: 3, turns: 1, threads: 1),
                dailyRows: [], modelRows: [], clientRows: [], rawCredits: 0, warnings: [],
                pricingVersion: "review-fixture", calculatedAt: now))
        })
    }
}
