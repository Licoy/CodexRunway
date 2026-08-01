import AppKit
import CodexRunwayCore
import Foundation
import SwiftUI

enum CostRangeQueryError: Error {
    case usageUnavailable
}

enum RunwayRefreshSection: CaseIterable, Hashable {
    case quota
    case resetCredits
    case rateLimitResetToday
    case apiCost
    case tokenHeatmap
    case sessionRepair
    case recentSessions
}

private enum RunwayModelAuthError: Error {
    case load(Error)
}

struct RunwayModelServices: Sendable {
    var loadValidAuth: @Sendable (_ preferCached: Bool, _ cachedAuth: CodexAuth?) async throws -> CodexAuth
    var fetchQuota: @Sendable (CodexAuth) async throws -> QuotaSnapshot
    var fetchResetCredits: @Sendable (CodexAuth) async throws -> ResetCreditsSnapshot
    var fetchRateLimitResetToday: @Sendable () async throws -> RateLimitResetTodaySnapshot
    var scanAPIEquivalent: @Sendable (
        [ApiCostQuery],
        Date,
        UsageCostRefreshPolicy,
        CostScanProgressReporter?
    ) async throws -> [String: ApiEquivalentSummary]
    var fetchDailyWorkspaceUsage: @Sendable (CodexAuth, String, String, DateInterval, Date) async throws -> ApiEquivalentSummary
    var fetchCodexProfileTokenUsage: @Sendable (CodexAuth) async throws -> CodexProfileTokenUsage
    var dryRunSessions: @Sendable () async throws -> SessionRepairReport
    var scanRecentSessions: @Sendable (Int) async throws -> SessionActivitySummary

    static func live(
        authStore: CodexAuthStore = CodexAuthStore(),
        quotaClient: QuotaClient = QuotaClient(),
        rateLimitResetTodayClient: RateLimitResetTodayClient = RateLimitResetTodayClient(),
        sessionRepair: SessionRepairService = SessionRepairService(),
        sessionActivityScanner: SessionActivityScanner = SessionActivityScanner()) -> Self
    {
        let costRepository = UsageCostRepository()
        return Self(
            loadValidAuth: { preferCached, cachedAuth in
                var auth = preferCached ? cachedAuth : nil
                if auth == nil {
                    do {
                        auth = try authStore.load()
                    } catch {
                        throw RunwayModelAuthError.load(error)
                    }
                }
                guard var validAuth = auth else { throw URLError(.userAuthenticationRequired) }
                switch validAuth.loginUsability {
                case .usable:
                    break
                case .invalidTokens:
                    throw RunwayModelAuthError.load(
                        NSError(domain: "CodexRunwayAuth", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "auth_file_invalid",
                        ]))
                case .expiredAccessWithoutRefresh:
                    throw RunwayModelAuthError.load(
                        NSError(domain: "CodexRunwayAuth", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: "auth_expired",
                        ]))
                }
                // Access-token-only session credentials: use while JWT valid; do not hit refresh.
                if TokenInspector.isExpired(validAuth.tokens.accessToken) {
                    guard validAuth.canRefreshOAuth else {
                        throw RunwayModelAuthError.load(
                            NSError(domain: "CodexRunwayAuth", code: 2, userInfo: [
                                NSLocalizedDescriptionKey: "auth_expired",
                            ]))
                    }
                    try await TokenRefresher().refresh(&validAuth, store: authStore)
                }
                return validAuth
            },
            fetchQuota: { auth in
                try await quotaClient.fetchQuota(auth: auth)
            },
            fetchResetCredits: { auth in
                try await quotaClient.fetchResetCredits(auth: auth)
            },
            fetchRateLimitResetToday: {
                try await rateLimitResetTodayClient.fetchStatus()
            },
            scanAPIEquivalent: { queries, calculatedAt, policy, progress in
                try await costRepository.summaries(
                    for: queries,
                    calculatedAt: calculatedAt,
                    policy: policy,
                    progress: progress)
            },
            fetchDailyWorkspaceUsage: { auth, startDate, endDate, window, calculatedAt in
                try await quotaClient.fetchDailyWorkspaceUsage(
                    auth: auth,
                    startDate: startDate,
                    endDate: endDate,
                    window: window,
                    calculatedAt: calculatedAt)
            },
            fetchCodexProfileTokenUsage: { auth in
                try await quotaClient.fetchCodexProfileTokenUsage(auth: auth)
            },
            dryRunSessions: {
                try await Task.detached {
                    try sessionRepair.dryRun()
                }.value
            },
            scanRecentSessions: { limit in
                try await Task.detached {
                    try sessionActivityScanner.scan(limit: limit)
                }.value
            })
    }
}

@MainActor
final class RunwayModel: ObservableObject {
    struct DetailLine: Identifiable {
        let id = UUID()
        let title: String
        let value: String
    }

    private struct CostCycleIdentity: Equatable {
        var reset: Date?
        var windowMinutes: Int?
    }

    private struct TokenHeatmapRemoteRequest {
        var auth: CodexAuth
        var localTokens: [String: Int]
        var calculatedAt: Date
        var accountGeneration: Int
    }

    @Published private(set) var selectedProvider: RunwayProvider
    @Published var statusText: String
    @Published var quotaText: String
    @Published var resetCreditsText: String
    @Published var rateLimitResetTodayText: String
    @Published var costText: String
    @Published var costSubtitle: String
    @Published var sessionText: String
    @Published var quotaLines: [DetailLine] = []
    @Published var resetCreditLines: [DetailLine] = []
    @Published var rateLimitResetTodayLines: [DetailLine] = []
    @Published var costLines: [DetailLine] = []
    @Published var sessionLines: [DetailLine] = []
    @Published var recentSessionLines: [DetailLine] = []
    @Published var quotaMeters: [QuotaMeter] = []
    @Published var resetCreditSummary: ResetCreditSummary?
    @Published var resetCreditDetails: [ResetCreditDetail] = []
    @Published var rateLimitResetToday: RateLimitResetTodaySnapshot?
    @Published var costDetail: ApiEquivalentSummary?
    /// Current-account official profile statistics — day → product-displayed tokens.
    @Published var tokenHeatmapAllDevicesTokens: [String: Int] = [:]
    /// All session logs on this Mac; historical entries may span accounts.
    @Published var tokenHeatmapLocalTokens: [String: Int] = [:]
    @Published var tokenHeatmapCalculatedAt: Date?
    @Published var tokenHeatmapOfficialStatsAsOf: String?
    @Published var tokenHeatmapOfficialGeneratedAt: Date?
    /// Grok local session day → tokens (same chart surface as Codex Token 用量).
    @Published var grokTokenHeatmapLocalTokens: [String: Int] = [:]
    @Published var grokTokenHeatmapCalculatedAt: Date?
    @Published var grokCostText: String = ""
    @Published var grokCostSubtitle: String = ""
    @Published var grokCostDetail: ApiEquivalentSummary?
    @Published var recentSessions: [SessionActivityItem] = []
    @Published var costScanNote: String?
    /// Scan progress lives on its own observable: it publishes ~10x/sec during a
    /// scan, and a model-level @Published write would re-layout the whole panel
    /// (including the PolishedScrollView height probe) on every tick.
    let costProgress = CostProgressModel()
    var costScanProgress: CostScanProgress { costProgress.progress }
    @Published var accountDisplay: CodexAccountDisplay
    @Published var managedAccounts: [ManagedAccount] = []
    @Published var activeAccountId: String?
    @Published var grokAccountState: GrokAccountState
    @Published var grokPanelState: GrokPanelViewState
    @Published var isRefreshingGrok = false
    @Published var grokRefreshingAccountIDs: Set<String> = []
    @Published var isGrokAccountOperationInProgress = false
    @Published var isGrokOAuthLoginInProgress = false
    @Published var grokAccountOperationMessage: String?
    @Published var grokLastError: String?
    @Published var grokRunningProcessWarningAccountID: String?
    @Published private(set) var isSwitchingAccount = false
    @Published private(set) var isRefreshingAccountQuotas = false
    @Published private(set) var refreshingAccountIds: Set<String> = []
    @Published var accountOperationMessage: String?
    @Published var lastError: String?
    @Published private(set) var refreshingSections: Set<RunwayRefreshSection> = []
    @Published private(set) var isRefreshingAll = false

    private let services: RunwayModelServices
    private let sessionRepair = SessionRepairService()
    private let costCacheStore: UsageCostCacheStore
    private let alertStore = RunwayAlertStore()
    private let statusExporter = RunwayStatusExporter()
    private let notificationService = RunwayNotificationService()
    let settings: RunwaySettings
    let grokModule: GrokAccountModule?
    let grokCLIAvailable: Bool
    private let costProgressReporter = CostScanProgressReporter()
    let accountStore: AccountStore
    private let accountSwitcher: AccountSwitcher
    private let accountImporter: AccountImporter
    private let accountQuotaRefresher: AccountQuotaRefresher
    private var latestAuth: CodexAuth?
    private var latestQuota: QuotaSnapshot?
    private var latestResetCredits: ResetCreditsSnapshot?
    private var lastRateLimitResetTodayFetch: Date?
    private var latestCost: ApiEquivalentSummary?
    private var latestCurrentCycleFullWindow: DateInterval?
    private var latestDisplayedCost: ApiEquivalentSummary?
    private var latestDisplayedCostRange: ApiCostSummaryRange?
    private var latestSessionReport: SessionRepairReport?
    private var lastSessionReportAt: Date?
    private var lastRecentSessionsAt: Date?
    private var lastCostRefreshCompletedAt: Date?
    private var lastCostCycleIdentity: CostCycleIdentity?
    private var detailCostCache: [String: ApiEquivalentSummary] = [:]
    private var detailCostCacheOrder: [String] = []
    private var detailCostInFlight: [String: Task<ApiEquivalentSummary, Error>] = [:]
    private var costProgressConsumers = 0
    private static let detailCostCacheLimit = 6
    private static let currentCostQueryID = "current-cycle"
    private static let selectedCostQueryID = "selected-range"
    private static let detailCostQueryID = "detail-range"
    private static let tokenHeatmapQueryID = "token-heatmap"
    private var lastTokenHeatmapRefreshCompletedAt: Date?
    private var accountStateGeneration = 0
    private var activeFullRefreshID: UUID?
    private var fullRefreshWork: Task<Void, Never>?
    private var activeTokenHeatmapRefreshID: UUID?
    private var tokenHeatmapRefreshWork: Task<Void, Never>?
    var grokRefreshGeneration = 0
    var grokRefreshWork: Task<Void, Never>?
    var grokRefreshCompletesFullRefresh = false
    var grokAccountOperationWork: Task<Void, Never>?
    var grokLocalUsageGeneration = 0
    var grokLocalUsageWork: Task<Void, Never>?
    var onFullRefreshCompleted: (() -> Void)?

    init(
        settings: RunwaySettings,
        services: RunwayModelServices = .live(),
        accountStore: AccountStore = AccountStore(),
        costCacheStore: UsageCostCacheStore = UsageCostCacheStore(),
        grokModule: GrokAccountModule? = nil,
        grokCLIAvailable: Bool = GrokExecutableLocator.locate() != nil)
    {
        self.settings = settings
        self.services = services
        self.accountStore = accountStore
        self.costCacheStore = costCacheStore
        self.grokModule = grokModule
        self.grokCLIAvailable = grokCLIAvailable
        self.accountSwitcher = AccountSwitcher(store: accountStore)
        self.accountImporter = AccountImporter(store: accountStore)
        self.accountQuotaRefresher = AccountQuotaRefresher(
            store: accountStore,
            switcher: AccountSwitcher(store: accountStore))
        let l10n = settings.l10n
        self.selectedProvider = settings.preferences.selectedProvider
        self.statusText = l10n.text(.statusLogin)
        self.quotaText = l10n.text(.notLoaded)
        self.resetCreditsText = l10n.text(.notLoaded)
        self.rateLimitResetTodayText = l10n.text(.notLoaded)
        self.costText = l10n.text(.notScanned)
        self.costSubtitle = ""
        self.grokCostText = l10n.text(.notScanned)
        self.grokCostSubtitle = ""
        self.sessionText = l10n.text(.notScanned)
        self.accountDisplay = CodexAccountDisplay.make(auth: nil, quotaPlan: nil)
        self.grokAccountState = GrokAccountState(
            officialCredentialStatus: .missing,
            currentAccountID: nil,
            accounts: [])
        self.grokPanelState = GrokPanelViewState(
            availability: grokModule == nil || !grokCLIAvailable ? .cliUnavailable : .loading)
        if let cached = costCacheStore.load() {
            applyCurrentCost(cached)
            if settings.preferences.apiCostSummaryRange == .current {
                applyDisplayedCost(cached, range: .current)
            }
        }
        costProgressReporter.setHandler { [weak self] progress in
            Task { @MainActor in
                self?.publishCostProgress(progress)
            }
        }
        bootstrapAccounts()
        bootstrapGrokAccounts()
    }

    /// Sidebar order: active first, then user sort.
    var sidebarAccounts: [ManagedAccount] {
        AccountIndex(activeAccountId: activeAccountId, accounts: managedAccounts).orderedForSidebar()
    }

    func bootstrapAccounts() {
        do {
            // Repairs broken official auth.json from a usable managed account when possible.
            let index = try accountStore.syncFromOfficialAuth()
            publishAccountIndex(index)
            if let auth = try? accountStore.loadOfficialAuth(), auth.loginUsability == .usable {
                latestAuth = auth
                accountDisplay = CodexAccountDisplay.make(auth: auth, quotaPlan: nil)
            }
        } catch {
            // Official auth may be missing on fresh machines.
            if let index = try? accountStore.loadIndex() {
                publishAccountIndex(index)
            }
        }
    }

    func reloadAccountIndex() {
        do {
            let index = try accountStore.loadIndex()
            publishAccountIndex(index)
        } catch {
            // Surface load failures — silent failure left the UI on a stale/empty list after import.
            lastError = "\(l10n.text(.accountsImportFailed)): \(error.localizedDescription)"
        }
    }

    /// Publish index to UI, forcing a new array identity so SwiftUI always refreshes rows.
    private func publishAccountIndex(_ index: AccountIndex) {
        managedAccounts = Array(index.accounts)
        activeAccountId = index.activeAccountId
    }

    func switchAccount(id: String, restartCodex: Bool = true) {
        guard id != activeAccountId, !isSwitchingAccount else { return }
        isSwitchingAccount = true
        accountOperationMessage = l10n.text(.accountsSwitching)
        Task {
            defer {
                isSwitchingAccount = false
            }
            do {
                let result = try await accountSwitcher.switchTo(accountId: id)
                await cancelAccountScopedRefreshes()
                // Drop previous account's quota/credits/cost so UI cannot keep showing the old plan.
                clearAccountScopedState(keepingAuth: result.auth)
                publishAccountIndex(try accountStore.loadIndex())
                accountDisplay = CodexAccountDisplay.make(
                    auth: result.auth,
                    quotaPlan: result.account.planType)
                lastError = nil
                // Reload main panel data for the new active account (must not reuse prior meters).
                refresh(policy: .force)
                if !isRefreshingAll {
                    refreshTokenHeatmap(policy: .force)
                }
                if restartCodex {
                    let restart = await CodexAppRestarter.restart()
                    if restart.relaunched || restart.terminatedCount > 0 {
                        accountOperationMessage = l10n.text(.accountsRestartCodexSucceeded)
                    } else {
                        let detail = restart.message ?? "unknown"
                        accountOperationMessage = nil
                        lastError = String(format: l10n.text(.accountsRestartCodexFailed), detail)
                    }
                } else {
                    accountOperationMessage = nil
                }
            } catch {
                accountOperationMessage = nil
                lastError = switchFailureMessage(error)
            }
        }
    }

    private func switchFailureMessage(_ error: Error) -> String {
        if let storeError = error as? AccountStoreError {
            switch storeError {
            case .missingRefreshToken, .expiredAccessWithoutRefresh:
                return l10n.text(.accountsSwitchSessionExpired)
            case .notUsableAsCodexLogin, .invalidCredential:
                return l10n.text(.accountsSwitchInvalidCredential)
            default:
                break
            }
        }
        return "\(l10n.text(.accountsSwitchFailed)): \(error.localizedDescription)"
    }

    func isRefreshingAccountQuota(id: String) -> Bool {
        refreshingAccountIds.contains(id) || isRefreshingAccountQuotas
    }

    func refreshAllAccountQuotas() {
        guard !isRefreshingAccountQuotas else { return }
        isRefreshingAccountQuotas = true
        let ids = Set(managedAccounts.map(\.id))
        // Reassign so @Published notifies (in-place Set mutation does not).
        refreshingAccountIds = refreshingAccountIds.union(ids)
        Task {
            defer {
                isRefreshingAccountQuotas = false
                refreshingAccountIds = refreshingAccountIds.subtracting(ids)
            }
            _ = await accountQuotaRefresher.refreshAll()
            reloadAccountIndex()
        }
    }

    func refreshAccountQuota(id: String) {
        guard !refreshingAccountIds.contains(id) else { return }
        refreshingAccountIds = refreshingAccountIds.union([id])
        Task {
            defer { refreshingAccountIds = refreshingAccountIds.subtracting([id]) }
            _ = await accountQuotaRefresher.refresh(accountId: id)
            reloadAccountIndex()
        }
    }

    func importOfficialAccount() {
        Task {
            do {
                let account = try accountImporter.importOfficial(makeActive: true)
                reloadAccountIndex()
                mergeImportedAccounts([account])
                accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), 1)
                lastError = nil
                refreshAllAccountQuotas()
            } catch {
                lastError = "\(l10n.text(.accountsImportFailed)): \(error.localizedDescription)"
            }
        }
    }

    /// Returns true when at least one account was imported successfully.
    @discardableResult
    func importPastedCredentials(_ text: String) async -> Bool {
        let batch = await accountImporter.importPastedText(text, makeActiveFirst: managedAccounts.isEmpty)
        // Reload index first so the settings list updates before the sheet closes.
        reloadAccountIndex()
        // Optimistic merge: ensure newly imported rows are visible even if index reload races.
        if batch.successCount > 0 {
            mergeImportedAccounts(batch.succeeded)
            accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), batch.successCount)
            lastError = batch.failureCount > 0
                ? "\(l10n.text(.accountsImportFailed)): \(humanizeImportFailures(batch.failures))"
                : nil
            // Quota refresh is background; do not block list visibility on it.
            refreshAllAccountQuotas()
            return true
        }
        accountOperationMessage = nil
        if batch.failures.contains("no_credentials") || batch.failures.isEmpty {
            lastError = l10n.text(.accountsImportNoCredentials)
        } else {
            lastError = "\(l10n.text(.accountsImportFailed)): \(humanizeImportFailures(batch.failures))"
        }
        return false
    }

    private func mergeImportedAccounts(_ imported: [ManagedAccount]) {
        var byID = Dictionary(uniqueKeysWithValues: managedAccounts.map { ($0.id, $0) })
        for account in imported {
            byID[account.id] = account
        }
        managedAccounts = Array(byID.values).sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.resolvedDisplayName.localizedCaseInsensitiveCompare(rhs.resolvedDisplayName)
                == .orderedAscending
        }
    }

    private func humanizeImportFailures(_ failures: [String]) -> String {
        failures.prefix(3).map { failure in
            if failure == "no_credentials" {
                return l10n.text(.accountsImportNoCredentials)
            }
            return failure
        }.joined(separator: "; ")
    }

    func importCredentialFiles(_ urls: [URL]) {
        Task {
            let batch = await accountImporter.importFiles(at: urls, makeActiveFirst: managedAccounts.isEmpty)
            reloadAccountIndex()
            if batch.successCount > 0 {
                mergeImportedAccounts(batch.succeeded)
                accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), batch.successCount)
                lastError = batch.failureCount > 0
                    ? "\(l10n.text(.accountsImportFailed)): \(batch.failures.prefix(3).joined(separator: "; "))"
                    : nil
                refreshAllAccountQuotas()
            } else if batch.failureCount > 0 {
                lastError = "\(l10n.text(.accountsImportFailed)): \(batch.failures.prefix(3).joined(separator: "; "))"
            }
        }
    }

    func importAPIKey(_ key: String) {
        Task {
            do {
                let account = try accountImporter.importAPIKey(key, makeActive: managedAccounts.isEmpty)
                reloadAccountIndex()
                mergeImportedAccounts([account])
                accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), 1)
                lastError = nil
                refreshAllAccountQuotas()
            } catch {
                lastError = "\(l10n.text(.accountsImportFailed)): \(error.localizedDescription)"
            }
        }
    }

    func startOAuthLogin() {
        Task {
            accountOperationMessage = l10n.text(.accountsOAuthWaiting)
            let server = OAuthCallbackServer()
            do {
                let session = try CodexOAuthLogin.startSession()
                NSWorkspace.shared.open(session.authURL)
                let callbackURL = try await server.waitForCallback()
                let code = try CodexOAuthLogin.authorizationCode(from: callbackURL, expectedState: session.state)
                let exchanged = try await CodexOAuthLogin.exchangeCode(code, session: session)
                let makeActive = managedAccounts.isEmpty
                let account = try accountStore.upsert(auth: exchanged.auth, makeActive: makeActive)
                if makeActive {
                    _ = try await accountSwitcher.switchTo(accountId: account.id)
                    refresh()
                }
                reloadAccountIndex()
                mergeImportedAccounts([account])
                accountOperationMessage = String(format: l10n.text(.accountsImportSucceeded), 1)
                lastError = nil
                refreshAllAccountQuotas()
            } catch OAuthCallbackServer.ServerError.cancelled {
                accountOperationMessage = l10n.text(.accountsOAuthCancelled)
            } catch {
                accountOperationMessage = nil
                lastError = "\(l10n.text(.accountsOAuthFailed)): \(error.localizedDescription)"
            }
        }
    }

    func deleteAccount(id: String) {
        Task {
            do {
                let wasActive = activeAccountId == id
                try accountStore.deleteAccount(id: id)
                reloadAccountIndex()
                if wasActive, let next = activeAccountId {
                    switchAccount(id: next)
                }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func moveAccount(id: String, direction: Int) {
        // direction: -1 up, +1 down in user sort (ignoring active pin).
        var nonActive = managedAccounts
            .filter { $0.id != activeAccountId }
            .sorted { $0.sortIndex < $1.sortIndex }
        guard let index = nonActive.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard nonActive.indices.contains(target) else { return }
        nonActive.swapAt(index, target)
        var orderedIds: [String] = []
        if let activeAccountId {
            orderedIds.append(activeAccountId)
        }
        orderedIds.append(contentsOf: nonActive.map(\.id))
        // Include any missing ids.
        for account in managedAccounts where !orderedIds.contains(account.id) {
            orderedIds.append(account.id)
        }
        try? accountStore.reorder(ids: orderedIds)
        reloadAccountIndex()
    }

    func updateAccountAlias(id: String, alias: String?) {
        guard var account = managedAccounts.first(where: { $0.id == id }) else { return }
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        account.alias = (trimmed?.isEmpty == false) ? trimmed : nil
        try? accountStore.updateMetadata(account)
        reloadAccountIndex()
    }

    var l10n: L10n { settings.l10n }

    func selectProvider(_ provider: RunwayProvider) {
        guard selectedProvider != provider else { return }
        let previous = selectedProvider
        selectedProvider = provider
        settings.updateSelectedProvider(provider)
        providerDidChange(from: previous)
    }

    var isRefreshing: Bool {
        if selectedProvider == .grok { return isRefreshingGrok }
        return isRefreshingAll || !refreshingSections.isEmpty
    }

    func isRefreshing(_ section: RunwayRefreshSection) -> Bool {
        refreshingSections.contains(section)
    }

    /// A hung leg (trickling response, first-time index rebuild) must never pin the
    /// refresh pipeline: every entry point guards on this state, and RefreshSchedule
    /// only re-arms via onFullRefreshCompleted.
    private static let fullRefreshWatchdogSeconds: UInt64 = 120

    func refresh(policy: UsageCostRefreshPolicy = .force) {
        if selectedProvider == .grok {
            refreshGrok(.current, completesFullRefresh: true)
            // Dual status bar still needs Codex quota even when the panel is Grok.
            if needsCodexStatusBarData, !isRefreshingAll {
                Task { await refreshQuotaNow() }
            }
            return
        }
        guard !isRefreshingAll, refreshingSections.isEmpty else { return }
        let refreshID = UUID()
        activeFullRefreshID = refreshID
        isRefreshingAll = true
        // Dual status bar still needs Grok quota even when the panel is Codex.
        if needsGrokStatusBarData {
            refreshGrok(.current)
        }
        let work = Task { await refreshNow(policy: policy) }
        fullRefreshWork = work
        Task {
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: Self.fullRefreshWatchdogSeconds * 1_000_000_000)
                work.cancel()
            }
            await work.value
            watchdog.cancel()
            finishFullRefresh(id: refreshID)
        }
    }

    func refreshQuota() {
        if selectedProvider == .grok {
            refreshGrok(.current)
            if needsCodexStatusBarData, !isRefreshingAll {
                Task { await refreshQuotaNow() }
            }
            return
        }
        if needsGrokStatusBarData {
            refreshGrok(.current)
        }
        guard !isRefreshingAll else { return }
        Task { await refreshQuotaNow() }
    }

    func refreshResetCredits() {
        guard !isRefreshingAll else { return }
        Task { await refreshResetCreditsNow() }
    }

    func refreshRateLimitResetToday(force: Bool = true) {
        guard settings.preferences.showsRateLimitResetToday else { return }
        guard !isRefreshing(.rateLimitResetToday) else { return }
        Task { await refreshRateLimitResetTodayNow(force: force) }
    }

    func refreshCost(policy: UsageCostRefreshPolicy = .force) {
        guard !isRefreshingAll,
              !refreshingSections.contains(.apiCost),
              shouldRefreshCost(policy: policy)
        else { return }
        refreshingSections.insert(.apiCost)
        Task {
            await refreshCostNow(policy: policy)
            refreshingSections.remove(.apiCost)
            exportStatusIfNeeded()
        }
    }

    func refreshTokenHeatmap(policy: UsageCostRefreshPolicy = .force) {
        guard settings.preferences.showsTokenUsageHeatmap else { return }
        guard !isRefreshingAll,
              !refreshingSections.contains(.tokenHeatmap),
              shouldRefreshTokenHeatmap(policy: policy)
        else { return }
        let refreshID = UUID()
        activeTokenHeatmapRefreshID = refreshID
        refreshingSections.insert(.tokenHeatmap)
        let work = Task {
            await refreshTokenHeatmapNow(policy: policy)
            finishTokenHeatmapRefresh(id: refreshID)
        }
        tokenHeatmapRefreshWork = work
    }

    func tokenHeatmapSnapshot(mode: TokenUsageHeatmapMode) -> TokenUsageHeatmapSnapshot {
        TokenUsageHeatmapBuilder.make(
            allDevicesTokens: tokenHeatmapAllDevicesTokens,
            localTokens: tokenHeatmapLocalTokens,
            mode: mode,
            now: tokenHeatmapCalculatedAt ?? Date())
    }

    func tick(now: Date = Date()) {
        // Equality-guard publishes: unconditional @Published writes force the entire
        // popover tree (including PolishedScrollView layout) to rebuild every second.
        if let latestQuota {
            let nextStatus = menuBarText(for: latestQuota, now: now)
            if statusText != nextStatus {
                statusText = nextStatus
            }
        }
        if let latestDisplayedCost, let latestDisplayedCostRange {
            let nextSubtitle = costSubtitle(for: latestDisplayedCost, range: latestDisplayedCostRange, now: now)
            if costSubtitle != nextSubtitle {
                costSubtitle = nextSubtitle
            }
        }
        if selectedProvider == .codex {
            refreshRateLimitResetTodayDisplayIfNeeded(now: now)
            refreshRateLimitResetTodayIfDue(now: now)
        }
    }

    func nextDueQuotaReset(after triggeredReset: Date?, now: Date = Date()) -> Date? {
        if selectedProvider == .grok {
            guard let reset = grokPanelState.quota?.meters.first?.resetsAt,
                  reset > (triggeredReset ?? .distantPast),
                  now.timeIntervalSince(reset) >= 1
            else { return nil }
            return reset
        }
        return latestQuota?.nextDueReset(after: triggeredReset, now: now)
    }

    /// Panel-open refreshes pass force=false: rescanning ~/.codex/sessions is
    /// O(files) heavy IO, and doing it on every open keeps the section spinners
    /// running for the whole visit on large session dirs.
    func refreshSessionReport(force: Bool = true) {
        guard !isRefreshingAll else { return }
        guard force || isStale(lastSessionReportAt) else { return }
        Task { await refreshSessionReportNow() }
    }

    func refreshRecentSessions(force: Bool = true) {
        guard !isRefreshingAll else { return }
        guard force || isStale(lastRecentSessionsAt) else { return }
        Task {
            await refreshRecentSessionsNow()
            exportStatusIfNeeded()
        }
    }

    private static let visibleSectionTTL: TimeInterval = 120

    private func isStale(_ lastSuccess: Date?) -> Bool {
        guard let lastSuccess else { return true }
        return Date().timeIntervalSince(lastSuccess) >= Self.visibleSectionTTL
    }

    func testNotification() -> String? {
        switch notificationService.deliverTest(l10n: l10n) {
        case .requested:
            return nil
        case .developmentMode:
            return l10n.text(.testNotificationDevelopmentMode)
        }
    }

    func repairSessions() {
        guard !isRefreshingAll else { return }
        Task {
            await withRefresh([.sessionRepair]) {
                do {
                    let service = sessionRepair
                    let report = try await Task.detached { try service.repair() }.value
                    applySessionReport(report)
                    let backup = report.backupPath?.lastPathComponent ?? l10n.text(.noPreviousIndex)
                    sessionText = "\(l10n.text(.rebuilt)) \(report.plannedEntries). \(l10n.text(.backup)): \(backup)"
                } catch {
                    sessionText = "\(l10n.text(.repairFailed)): \(error.localizedDescription)"
                }
            }
        }
    }

    var repairWarning: String {
        l10n.text(.repairConfirmMessage)
    }

    func relabel() {
        rebuildGrokPanelState()
        // Prefer live quota plan only when we still have a matching snapshot; else JWT/auth only.
        accountDisplay = CodexAccountDisplay.make(auth: latestAuth, quotaPlan: latestQuota?.plan)
        if let latestQuota {
            applyQuota(latestQuota)
        } else {
            statusText = l10n.text(.statusLogin)
            quotaText = l10n.text(.notLoaded)
            quotaMeters = []
            quotaLines = []
        }
        if let latestResetCredits { applyResetCredits(latestResetCredits) } else { resetCreditsText = l10n.text(.notLoaded) }
        if let rateLimitResetToday {
            applyRateLimitResetToday(rateLimitResetToday)
        } else if settings.preferences.showsRateLimitResetToday {
            rateLimitResetTodayText = l10n.text(.notLoaded)
            rateLimitResetTodayLines = []
        } else {
            rateLimitResetTodayText = l10n.text(.notLoaded)
            rateLimitResetTodayLines = []
        }
        if let latestDisplayedCost, let latestDisplayedCostRange {
            applyDisplayedCost(latestDisplayedCost, range: latestDisplayedCostRange, clearsScanNote: false)
        } else {
            costText = l10n.text(.notScanned)
            costSubtitle = ""
        }
        if let latestSessionReport { applySessionReport(latestSessionReport) } else { sessionText = l10n.text(.notScanned) }
        applyRecentSessions(recentSessions)
        // Turning the section on should fetch promptly without waiting for the next due tick.
        if selectedProvider == .codex,
           settings.preferences.showsRateLimitResetToday,
           rateLimitResetToday == nil
        {
            refreshRateLimitResetToday(force: true)
        }
    }

    private func refreshSessionReportNow() async {
        await withRefresh([.sessionRepair]) {
            await loadSessionReport()
        }
    }

    private func loadSessionReport() async {
        do {
            let report = try await services.dryRunSessions()
            applySessionReport(report)
            lastSessionReportAt = Date()
        } catch {
            sessionText = l10n.text(.sessionScanFailed)
            sessionLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
        }
    }

    private func applySessionReport(_ report: SessionRepairReport) {
        latestSessionReport = report
        sessionText = "\(report.missingIndexIDs.count) \(l10n.text(.missing)), \(report.orphanIndexIDs.count) \(l10n.text(.orphan)), \(report.duplicateIndexIDs.count) \(l10n.text(.duplicate))"
        sessionLines = [
            DetailLine(title: l10n.text(.plannedEntries), value: "\(report.plannedEntries)"),
            DetailLine(title: l10n.text(.missingFromIndex), value: "\(report.missingIndexIDs.count)"),
            DetailLine(title: l10n.text(.orphanIndexRows), value: "\(report.orphanIndexIDs.count)"),
            DetailLine(title: l10n.text(.duplicateIndexIDs), value: "\(report.duplicateIndexIDs.count)"),
            DetailLine(title: l10n.text(.staleTitles), value: "\(report.staleTitleIDs.count)"),
        ]
        if let backup = report.backupPath?.lastPathComponent {
            sessionLines.append(DetailLine(title: l10n.text(.backup), value: backup))
        }
    }

    private func refreshRecentSessionsNow() async {
        await withRefresh([.recentSessions]) {
            await loadRecentSessions()
        }
    }

    private func loadRecentSessions() async {
        do {
            let summary = try await services.scanRecentSessions(5)
            applyRecentSessions(summary.items)
            lastRecentSessionsAt = Date()
        } catch {
            recentSessions = []
            recentSessionLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
        }
    }

    private func applyRecentSessions(_ sessions: [SessionActivityItem]) {
        recentSessions = sessions
        recentSessionLines = sessions.prefix(5).map { session in
            let amount = session.estimatedUSD.map(DurationFormatter.money) ?? "--"
            return DetailLine(
                title: session.projectName,
                value: "\(sessionStateText(session.state)) · \(Self.compactNumber(session.totals.totalTokens)) \(l10n.text(.tokens)) · \(amount)")
        }
    }

    private func deliverAlerts(_ alerts: [RunwayAlert], enabled: Bool) {
        guard enabled, !alerts.isEmpty else { return }
        do {
            let unseen = try alertStore.unseen(alerts)
            notificationService.deliver(unseen, l10n: l10n)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func exportStatusIfNeeded() {
        guard settings.preferences.exportsStatusJSON else { return }
        let snapshot = RunwayStatusSnapshot(
            quota: latestQuota.map(RunwayStatusQuota.init),
            cost: latestCost,
            sessions: SessionActivitySummary(items: recentSessions))
        let exporter = statusExporter
        Task.detached { try? exporter.save(snapshot) }
    }

    private func withRefresh(_ sections: Set<RunwayRefreshSection>, operation: () async -> Void) async {
        guard refreshingSections.isDisjoint(with: sections) else { return }
        refreshingSections.formUnion(sections)
        defer { refreshingSections.subtract(sections) }
        await operation()
    }

    private func refreshNow(policy: UsageCostRefreshPolicy) async {
        // Keep managed account list aligned with official CLI auth before loading tokens.
        if let index = try? accountStore.syncFromOfficialAuth() {
            publishAccountIndex(index)
        }
        let shouldRefreshSessions = settings.preferences.showsSessionRepairSummary
        let shouldRefreshRecent = settings.preferences.showsRecentSessions
        async let sessionReport: Void = refreshSessionReportIfNeeded(shouldRefreshSessions)
        async let recentSessions: Void = refreshRecentSessionsIfNeeded(shouldRefreshRecent)
        // Multi-account quota polling must not block the primary refresh path (or unit tests).
        Task { await refreshAllAccountQuotasInline() }
        var remoteError: Error?
        do {
            let auth = try await loadValidAuth(preferCached: false)
            async let quotaResultTask = refreshQuotaForFullRefresh(auth: auth)
            async let resetErrorTask = refreshResetCreditsForFullRefresh(auth: auth)
            let quotaResult = await quotaResultTask
            if case .success(let quotaSnapshot) = quotaResult {
                let needsCost =
                    settings.preferences.showsCostSummary
                    && shouldRefreshCost(policy: policy, quota: quotaSnapshot)
                let needsHeatmap =
                    settings.preferences.showsTokenUsageHeatmap
                    && shouldRefreshTokenHeatmap(policy: policy)
                if needsCost || needsHeatmap {
                    var sections = Set<RunwayRefreshSection>()
                    if needsCost { sections.insert(.apiCost) }
                    if needsHeatmap { sections.insert(.tokenHeatmap) }
                    await withRefresh(sections) {
                        await scanCostAndHeatmap(
                            quotaSnapshot,
                            auth: auth,
                            policy: policy,
                            includeCost: needsCost,
                            includeHeatmap: needsHeatmap)
                        if needsCost {
                            markCostRefreshCompleted(quota: quotaSnapshot)
                        }
                        if needsHeatmap {
                            markTokenHeatmapRefreshCompleted()
                        }
                    }
                }
            }
            if case .failure(let error) = quotaResult {
                remoteError = error
            }
            if let resetError = await resetErrorTask {
                remoteError = resetError
            }
        } catch {
            remoteError = error
            statusText = l10n.text(.statusError)
            // Auth hard-failure: keep a clear login state instead of a raw NSURLError.
            if isAuthenticationFailure(error) {
                accountDisplay = CodexAccountDisplay.make(auth: nil, quotaPlan: nil)
                statusText = l10n.text(.statusLogin)
            }
        }
        _ = await (sessionReport, recentSessions)
        exportStatusIfNeeded()
        lastError = remoteError.map(humanizeAuthError)
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        if error is RunwayModelAuthError { return true }
        if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
            return true
        }
        let ns = error as NSError
        if ns.domain == "CodexRunwayAuth" { return true }
        return ns.domain == NSURLErrorDomain && ns.code == URLError.userAuthenticationRequired.rawValue
    }

    private func humanizeAuthError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "CodexRunwayAuth" {
            switch ns.localizedDescription {
            case "auth_file_invalid":
                return l10n.text(.authFileInvalid)
            case "auth_expired":
                return l10n.text(.authExpired)
            default:
                return l10n.text(.authFileInvalid)
            }
        }
        if isAuthenticationFailure(error) {
            if let auth = try? accountStore.loadOfficialAuth() {
                switch auth.loginUsability {
                case .invalidTokens:
                    return l10n.text(.authFileInvalid)
                case .expiredAccessWithoutRefresh:
                    return l10n.text(.authExpired)
                case .usable:
                    break
                }
            }
            return l10n.text(.authExpired)
        }
        return error.localizedDescription
    }

    private func refreshAllAccountQuotasInline() async {
        guard !isRefreshingAccountQuotas else { return }
        isRefreshingAccountQuotas = true
        let ids = Set(managedAccounts.map(\.id))
        refreshingAccountIds = refreshingAccountIds.union(ids)
        defer {
            isRefreshingAccountQuotas = false
            refreshingAccountIds = refreshingAccountIds.subtracting(ids)
        }
        _ = await accountQuotaRefresher.refreshAll()
        reloadAccountIndex()
    }

    private func refreshSessionReportIfNeeded(_ isShown: Bool) async {
        guard isShown else { return }
        await refreshSessionReportNow()
    }

    private func refreshRecentSessionsIfNeeded(_ isShown: Bool) async {
        guard isShown else { return }
        await refreshRecentSessionsNow()
    }

    private func refreshQuotaForFullRefresh(auth: CodexAuth) async -> Result<QuotaSnapshot, Error> {
        var result: Result<QuotaSnapshot, Error> = .failure(CancellationError())
        await withRefresh([.quota]) {
            do {
                let snapshot = try await services.fetchQuota(auth)
                latestQuota = snapshot
                applyQuota(snapshot)
                deliverAlerts(RunwayAlertDecider.quotaAlerts(snapshot), enabled: settings.preferences.quotaAlertsEnabled)
                result = .success(snapshot)
            } catch {
                statusText = l10n.text(.statusError)
                quotaText = l10n.text(.statusError)
                quotaLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
                result = .failure(error)
            }
        }
        return result
    }

    private func refreshResetCreditsForFullRefresh(auth: CodexAuth) async -> Error? {
        var refreshError: Error?
        await withRefresh([.resetCredits]) {
            do {
                let snapshot = try await services.fetchResetCredits(auth)
                latestResetCredits = snapshot
                applyResetCredits(snapshot)
                deliverAlerts(RunwayAlertDecider.resetCreditAlerts(snapshot), enabled: settings.preferences.resetCreditAlertsEnabled)
            } catch {
                resetCreditsText = l10n.text(.statusError)
                resetCreditLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
                refreshError = error
            }
        }
        return refreshError
    }

    private func refreshQuotaNow() async {
        await withRefresh([.quota]) {
            do {
                let auth = try await loadValidAuth(preferCached: false)
                let quotaSnapshot = try await services.fetchQuota(auth)
                latestQuota = quotaSnapshot
                applyQuota(quotaSnapshot)
                deliverAlerts(RunwayAlertDecider.quotaAlerts(quotaSnapshot), enabled: settings.preferences.quotaAlertsEnabled)
                lastError = nil
                exportStatusIfNeeded()
            } catch {
                statusText = l10n.text(.statusError)
                quotaText = l10n.text(.statusError)
                quotaLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
                lastError = error.localizedDescription
            }
        }
    }

    private func refreshResetCreditsNow() async {
        await withRefresh([.resetCredits]) {
            do {
                let auth = try await loadValidAuth(preferCached: true)
                let snapshot = try await services.fetchResetCredits(auth)
                latestResetCredits = snapshot
                applyResetCredits(snapshot)
                deliverAlerts(RunwayAlertDecider.resetCreditAlerts(snapshot), enabled: settings.preferences.resetCreditAlertsEnabled)
                lastError = nil
                exportStatusIfNeeded()
            } catch {
                resetCreditsText = l10n.text(.statusError)
                resetCreditLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
                lastError = error.localizedDescription
            }
        }
    }

    private func refreshRateLimitResetTodayIfDue(now: Date) {
        guard settings.preferences.showsRateLimitResetToday else { return }
        guard !isRefreshing(.rateLimitResetToday) else { return }
        let interval = TimeInterval(settings.preferences.rateLimitResetTodayRefreshIntervalSeconds)
        if let last = lastRateLimitResetTodayFetch, now.timeIntervalSince(last) < interval {
            return
        }
        refreshRateLimitResetToday(force: false)
    }

    private func refreshRateLimitResetTodayDisplayIfNeeded(now: Date) {
        guard let snapshot = rateLimitResetToday else { return }
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        // Re-check approaching scheduled resets on the local timer (refresh may be hourly).
        deliverAlerts(
            RunwayAlertDecider.rateLimitResetTodayAlerts(
                previous: snapshot,
                current: snapshot,
                now: now,
                calendar: calendar),
            enabled: settings.preferences.rateLimitResetTodayAlertsEnabled)
        let state = snapshot.resolvedState(now: now, calendar: calendar)
        let stateText = rateLimitResetTodayStateText(state)
        if rateLimitResetTodayText != stateText {
            rateLimitResetTodayText = stateText
        }
        let hintText = rateLimitResetTodayHintText(snapshot, now: now)
        guard let statusIndex = rateLimitResetTodayLines.firstIndex(where: {
            $0.title == l10n.text(.status)
        }), rateLimitResetTodayLines[statusIndex].value != hintText
        else {
            return
        }
        var lines = rateLimitResetTodayLines
        lines[statusIndex] = DetailLine(title: l10n.text(.status), value: hintText)
        // Rebuild next-schedule line when local midnight changes the answer context.
        if let next = snapshot.nextScheduledReset(now: now) {
            let nextValue = ResetLabelFormatter.shortLabel(
                for: next.effectiveAt,
                now: now,
                language: l10n.language,
                calendar: calendar)
            if let nextIndex = lines.firstIndex(where: { $0.title == l10n.text(.rateLimitResetTodayNextScheduled) }) {
                lines[nextIndex] = DetailLine(
                    title: l10n.text(.rateLimitResetTodayNextScheduled),
                    value: nextValue)
            } else {
                lines.insert(
                    DetailLine(
                        title: l10n.text(.rateLimitResetTodayNextScheduled),
                        value: nextValue),
                    at: min(1, lines.count))
            }
        } else {
            lines.removeAll { $0.title == l10n.text(.rateLimitResetTodayNextScheduled) }
        }
        rateLimitResetTodayLines = lines
    }

    private func refreshRateLimitResetTodayNow(force: Bool) async {
        guard settings.preferences.showsRateLimitResetToday else { return }
        if !force,
           let last = lastRateLimitResetTodayFetch
        {
            let interval = TimeInterval(settings.preferences.rateLimitResetTodayRefreshIntervalSeconds)
            if Date().timeIntervalSince(last) < interval { return }
        }
        await withRefresh([.rateLimitResetToday]) {
            do {
                let snapshot = try await services.fetchRateLimitResetToday()
                applyRateLimitResetToday(snapshot)
                lastRateLimitResetTodayFetch = Date()
            } catch {
                lastRateLimitResetTodayFetch = Date()
                // Keep the last good snapshot; only mark error text when nothing is loaded yet.
                if rateLimitResetToday == nil {
                    rateLimitResetTodayText = l10n.text(.statusError)
                    rateLimitResetTodayLines = [
                        DetailLine(title: l10n.text(.error), value: error.localizedDescription),
                    ]
                }
            }
        }
    }

    private func applyRateLimitResetToday(_ snapshot: RateLimitResetTodaySnapshot) {
        let previous = rateLimitResetToday
        rateLimitResetToday = snapshot
        let now = Date()
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        let state = snapshot.resolvedState(now: now, calendar: calendar)
        rateLimitResetTodayText = rateLimitResetTodayStateText(state)
        deliverAlerts(
            RunwayAlertDecider.rateLimitResetTodayAlerts(
                previous: previous,
                current: snapshot,
                now: now,
                calendar: calendar),
            enabled: settings.preferences.rateLimitResetTodayAlertsEnabled)
        var lines: [DetailLine] = [
            DetailLine(title: l10n.text(.status), value: rateLimitResetTodayHintText(snapshot, now: now)),
        ]
        if let next = snapshot.nextScheduledReset(now: now) {
            lines.append(
                DetailLine(
                    title: l10n.text(.rateLimitResetTodayNextScheduled),
                    value: ResetLabelFormatter.shortLabel(
                        for: next.effectiveAt,
                        now: now,
                        language: l10n.language,
                        calendar: calendar)))
        }
        if let checkedAt = snapshot.lastSuccessfulCheckAt {
            lines.append(
                DetailLine(
                    title: l10n.text(.rateLimitResetTodayLastCheck),
                    value: DurationFormatter.relativePast(since: checkedAt, language: l10n.language)))
        }
        if let evidence = snapshot.evidenceLine(l10n: l10n, now: now, calendar: calendar) {
            lines.append(
                DetailLine(
                    title: l10n.text(.rateLimitResetTodayLatestEvidence),
                    value: evidence))
        }
        if let event = snapshot.primaryEvidenceEvent(now: now, calendar: calendar),
           let scope = snapshot.scopeSummary(for: event, l10n: l10n)
        {
            lines.append(
                DetailLine(
                    title: l10n.text(.rateLimitResetTodayPlans),
                    value: scope))
        }
        if let event = snapshot.primaryEvidenceEvent(now: now, calendar: calendar) {
            lines.append(
                DetailLine(
                    title: l10n.text(.rateLimitResetTodayConfidence),
                    value: "\(Int((event.confidence * 100).rounded()))%"))
        }
        if let resetAt = snapshot.latestResetAt(now: now) {
            lines.append(
                DetailLine(
                    title: l10n.text(.lastReset),
                    value: ResetLabelFormatter.shortLabel(
                        for: resetAt,
                        now: now,
                        language: l10n.language,
                        calendar: calendar)))
        }
        lines.append(
            DetailLine(
                title: l10n.text(.rateLimitResetTodayLastFetched),
                value: DurationFormatter.relativePast(since: snapshot.fetchedAt, language: l10n.language)))
        rateLimitResetTodayLines = lines
    }

    private func rateLimitResetTodayStateText(_ state: RateLimitResetTodayState) -> String {
        switch state {
        case .yes:
            return l10n.text(.rateLimitResetTodayYes)
        case .no:
            return l10n.text(.rateLimitResetTodayNo)
        case .unknown:
            return l10n.text(.rateLimitResetTodayUnknown)
        }
    }

    private func rateLimitResetTodayHintText(
        _ snapshot: RateLimitResetTodaySnapshot,
        now: Date) -> String
    {
        let calendar = RateLimitResetTodaySnapshot.localDayCalendar
        switch snapshot.resolvedState(now: now, calendar: calendar) {
        case .yes:
            // Prefer the next same-day schedule when today has multiple resets.
            if let next = snapshot.nextScheduledReset(onLocalDayOf: now, calendar: calendar) {
                let when = ResetLabelFormatter.shortLabel(
                    for: next.effectiveAt,
                    now: now,
                    language: l10n.language,
                    calendar: calendar)
                return String(format: l10n.text(.rateLimitResetTodayYesHintScheduledWithTime), when)
            }
            if let resetAt = snapshot.latestResetAt(now: now) {
                let when = ResetLabelFormatter.shortLabel(
                    for: resetAt,
                    now: now,
                    language: l10n.language,
                    calendar: calendar)
                return String(format: l10n.text(.rateLimitResetTodayYesHintWithTime), when)
            }
            return l10n.text(.rateLimitResetTodayYesHint)
        case .no:
            if let next = snapshot.nextScheduledReset(now: now) {
                let when = ResetLabelFormatter.shortLabel(
                    for: next.effectiveAt,
                    now: now,
                    language: l10n.language,
                    calendar: calendar)
                return String(format: l10n.text(.rateLimitResetTodayNoHintWithNext), when)
            }
            return l10n.text(.rateLimitResetTodayNoHint)
        case .unknown:
            return l10n.text(.rateLimitResetTodayUnknownHint)
        }
    }

    private func refreshCostNow(policy: UsageCostRefreshPolicy) async {
        do {
            let auth = try await loadValidAuth(preferCached: true)
            let quotaSnapshot = try await services.fetchQuota(auth)
            latestQuota = quotaSnapshot
            applyQuota(quotaSnapshot)
            await scanCostAndHeatmap(
                quotaSnapshot,
                auth: auth,
                policy: policy,
                includeCost: true,
                includeHeatmap: false)
            markCostRefreshCompleted(quota: quotaSnapshot)
            lastError = nil
        } catch {
            if latestDisplayedCost != nil {
                noteCostScanFailure(error.localizedDescription)
            } else {
                clearDisplayedCost(l10n.text(.usageAnalyticsUnavailable))
                costLines = [DetailLine(title: l10n.text(.error), value: error.localizedDescription)]
            }
            lastError = error.localizedDescription
        }
    }

    private func shouldRefreshCost(
        policy: UsageCostRefreshPolicy,
        quota: QuotaSnapshot? = nil,
        now: Date = Date()
    ) -> Bool {
        guard policy == .ifChanged, let lastCostRefreshCompletedAt else { return true }
        if let quota, costCycleIdentity(for: quota) != lastCostCycleIdentity { return true }
        let interval = TimeInterval(settings.preferences.refreshIntervalSeconds)
        return now >= lastCostRefreshCompletedAt.addingTimeInterval(interval)
    }

    private func markCostRefreshCompleted(quota: QuotaSnapshot, at completion: Date = Date()) {
        lastCostRefreshCompletedAt = completion
        lastCostCycleIdentity = costCycleIdentity(for: quota)
    }

    private func shouldRefreshTokenHeatmap(
        policy: UsageCostRefreshPolicy,
        now: Date = Date()
    ) -> Bool {
        guard policy == .ifChanged, let lastTokenHeatmapRefreshCompletedAt else { return true }
        let interval = TimeInterval(settings.preferences.refreshIntervalSeconds)
        return now >= lastTokenHeatmapRefreshCompletedAt.addingTimeInterval(interval)
    }

    private func markTokenHeatmapRefreshCompleted(at completion: Date = Date()) {
        lastTokenHeatmapRefreshCompletedAt = completion
    }

    private func refreshTokenHeatmapNow(policy: UsageCostRefreshPolicy) async {
        do {
            let auth = try await loadValidAuth(preferCached: true)
            try await scanTokenHeatmap(auth: auth, policy: policy)
            markTokenHeatmapRefreshCompleted()
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            // Keep previous grid when a refresh fails; first load stays empty.
            if tokenHeatmapAllDevicesTokens.isEmpty, tokenHeatmapLocalTokens.isEmpty {
                tokenHeatmapCalculatedAt = Date()
            }
            lastError = l10n.text(.tokenUsageHeatmapUnavailable)
        }
    }

    private func scanTokenHeatmap(auth: CodexAuth, policy: UsageCostRefreshPolicy) async throws {
        let expectedGeneration = accountStateGeneration
        let now = Date()
        let window = TokenUsageHeatmapBuilder.yearToDateWindow(now: now)
        let query = ApiCostQuery(id: Self.tokenHeatmapQueryID, window: window)

        // Collect both independent series. The official profile activity endpoint
        // has a different token definition from workspace analytics.
        let local = try await localCostSummaries(queries: [query], now: now, policy: policy)
        let localMap = local[Self.tokenHeatmapQueryID].map(dailyTokenMap(from:)) ?? [:]
        try Task.checkCancellation()
        guard isCurrentAccount(auth, generation: expectedGeneration) else {
            throw CancellationError()
        }
        applyLocalTokenHeatmap(localMap, now: now)
        try await fetchAndApplyProfileTokenHeatmap(TokenHeatmapRemoteRequest(
            auth: auth,
            localTokens: localMap,
            calculatedAt: now,
            accountGeneration: expectedGeneration))
    }

    private func dailyTokenMap(from summary: ApiEquivalentSummary) -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(summary.dailyRows.count)
        for row in summary.dailyRows {
            map[row.date, default: 0] += max(0, row.totals.totalTokens)
        }
        return map
    }

    private func applyTokenHeatmap(
        allDevices: [String: Int],
        local: [String: Int],
        officialStatsAsOf: String?,
        officialGeneratedAt: Date?,
        now: Date
    ) {
        if allDevices != tokenHeatmapAllDevicesTokens {
            tokenHeatmapAllDevicesTokens = allDevices
        }
        if local != tokenHeatmapLocalTokens {
            tokenHeatmapLocalTokens = local
        }
        tokenHeatmapOfficialStatsAsOf = officialStatsAsOf
        tokenHeatmapOfficialGeneratedAt = officialGeneratedAt
        tokenHeatmapCalculatedAt = now
    }

    private func applyLocalTokenHeatmap(_ local: [String: Int], now: Date) {
        if local != tokenHeatmapLocalTokens {
            tokenHeatmapLocalTokens = local
        }
        tokenHeatmapCalculatedAt = now
    }

    private func costCycleIdentity(for quota: QuotaSnapshot) -> CostCycleIdentity {
        CostCycleIdentity(
            reset: quota.secondary?.resetsAt,
            windowMinutes: quota.secondary?.windowMinutes)
    }

    func queryCost(range: ApiCostRange) async throws -> ApiEquivalentSummary {
        if selectedProvider == .grok {
            return try await queryGrokCost(range: range)
        }
        let key = Self.detailCacheKey(for: range)
        if let cached = detailCostCache[key] {
            return cached
        }

        let task: Task<ApiEquivalentSummary, Error>
        if let existing = detailCostInFlight[key] {
            task = existing
        } else {
            // Unstructured so navigating away does not cancel the scan; results land in cache.
            task = Task { @MainActor in
                defer { self.detailCostInFlight[key] = nil }
                let summary = try await self.performDetailCostQuery(range: range)
                self.storeDetailCostCache(summary, key: key)
                return summary
            }
            detailCostInFlight[key] = task
        }

        return try await task.value
    }

    /// Loads current-cycle cost for the detail page without treating a missing
    /// snapshot as an immediate hard failure.
    func queryCurrentCycleCost() async throws -> ApiEquivalentSummary {
        if selectedProvider == .grok {
            let range = try await resolveGrokCurrentCycleCostRange()
            if let grokCostDetail,
               grokCostDetail.isDisplayableCost,
               abs(grokCostDetail.window.start.timeIntervalSince(range.window.start)) < 60,
               grokCostDetail.window.end <= range.window.end.addingTimeInterval(120)
            {
                return grokCostDetail
            }
            return try await queryGrokCost(range: range)
        }
        let now = Date()
        let range = try await resolveCurrentCycleCostRange(now: now)
        // Reuse an in-memory current-cycle snapshot only when its window still matches.
        if let costDetail,
           costDetail.isDisplayableCost,
           abs(costDetail.window.start.timeIntervalSince(range.window.start)) < 60,
           costDetail.window.end <= range.window.end.addingTimeInterval(120)
        {
            return costDetail
        }
        return try await queryCost(range: range)
    }

    func previousCycleCostRange() -> ApiCostRange? {
        if selectedProvider == .grok {
            return grokCurrentCycleFullWindow.map { ApiCostRange.previousCycle(from: $0) }
        }
        return latestCurrentCycleFullWindow.map { ApiCostRange.previousCycle(from: $0) }
    }

    /// Resolves the previous quota cycle window, fetching quota first when needed.
    func resolvePreviousCycleCostRange() async throws -> ApiCostRange {
        if selectedProvider == .grok {
            if let range = previousCycleCostRange() { return range }
            let full = try await resolveGrokCurrentCycleCostRange().window
            // previousCycle needs the full cycle window, not elapsed.
            let fullWindow = grokCurrentCycleFullWindow ?? full
            return ApiCostRange.previousCycle(from: fullWindow)
        }
        if let range = previousCycleCostRange() { return range }
        let full = try await ensureCurrentCycleFullWindow()
        return ApiCostRange.previousCycle(from: full)
    }

    private func resolveCurrentCycleCostRange(now: Date = Date()) async throws -> ApiCostRange {
        let windows = try await ensureCurrentCycleWindows(now: now)
        return .range(window: windows.elapsed)
    }

    private var grokCurrentCycleFullWindow: DateInterval? {
        guard let period = grokPanelState.quota?.meters.first?.resetsAt,
              let startsHint = grokAccountState.accounts
                .first(where: { $0.id == grokAccountState.currentAccountID })?
                .cachedQuota?.period
        else { return nil }
        if let start = startsHint.startsAt, let end = startsHint.resetsAt, end > start {
            return DateInterval(start: start, end: end)
        }
        _ = period
        return nil
    }

    private func resolveGrokCurrentCycleCostRange(now: Date = Date()) async throws -> ApiCostRange {
        if let full = grokCurrentCycleFullWindow {
            let elapsed = DateInterval(start: full.start, end: min(now, full.end))
            return .range(window: elapsed)
        }
        // Fallback: rolling 7 days when billing period is unknown.
        let week: TimeInterval = 7 * 24 * 3_600
        return .range(window: DateInterval(start: now.addingTimeInterval(-week), end: now))
    }

    private func queryGrokCost(range: ApiCostRange) async throws -> ApiEquivalentSummary {
        guard range.window.end > range.window.start else {
            throw CostRangeQueryError.usageUnavailable
        }
        let key = "grok|" + Self.detailCacheKey(for: range)
        if let cached = detailCostCache[key] {
            return cached
        }
        let summary = try await Task.detached(priority: .utility) {
            try GrokSessionScanner().scanCost(window: range.window)
        }.value
        storeDetailCostCache(summary, key: key)
        return summary
    }

    private func ensureCurrentCycleFullWindow(now: Date = Date()) async throws -> DateInterval {
        try await ensureCurrentCycleWindows(now: now).full
    }

    private func ensureCurrentCycleWindows(now: Date = Date()) async throws -> (full: DateInterval, elapsed: DateInterval) {
        if let latestQuota, let windows = currentCycleWindows(from: latestQuota, now: now) {
            latestCurrentCycleFullWindow = windows.full
            return windows
        }
        beginCostProgress()
        defer { endCostProgress() }
        publishCostProgress(.preparing, force: true)
        let auth = try await loadValidAuth(preferCached: true)
        let quotaSnapshot = try await services.fetchQuota(auth)
        latestQuota = quotaSnapshot
        applyQuota(quotaSnapshot)
        if let windows = currentCycleWindows(from: quotaSnapshot, now: now) {
            latestCurrentCycleFullWindow = windows.full
            return windows
        }
        // Soft fallback: treat the last 7 days as the current cycle so local scans
        // still work when quota payloads omit reset/window metadata.
        let week: TimeInterval = 7 * 24 * 3_600
        let fallbackFull = DateInterval(start: now.addingTimeInterval(-week), end: now)
        latestCurrentCycleFullWindow = fallbackFull
        return (fallbackFull, fallbackFull)
    }

    private func performDetailCostQuery(range: ApiCostRange) async throws -> ApiEquivalentSummary {
        let now = Date()
        beginCostProgress()
        defer { endCostProgress() }
        publishCostProgress(.preparing, force: true)
        let auth = try await loadValidAuth(preferCached: true)
        return try await queryCost(range: range, auth: auth, now: now, useSharedFlight: true)
    }

    private func queryCost(
        range: ApiCostRange,
        auth: CodexAuth,
        now: Date,
        useSharedFlight: Bool
    ) async throws -> ApiEquivalentSummary {
        // Guard inverted/empty windows that always produce "unavailable".
        guard range.window.end > range.window.start else {
            throw CostRangeQueryError.usageUnavailable
        }
        let query = ApiCostQuery(id: Self.detailCostQueryID, window: range.window)
        let local: ApiEquivalentSummary?
        do {
            local = try await services.scanAPIEquivalent(
                [query],
                now,
                .ifChanged,
                useSharedFlight ? costProgressReporter : nil)[query.id]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            local = nil
        }
        return try await resolveCost(local: local, range: range, auth: auth, now: now)
    }

    private func resolveCost(
        local: ApiEquivalentSummary?,
        range: ApiCostRange,
        auth: CodexAuth,
        now: Date
    ) async throws -> ApiEquivalentSummary {
        try Task.checkCancellation()
        if let local, local.isDisplayableCost { return local }
        publishCostProgress(.fetchingOnline, force: true)
        do {
            let summary = try await services.fetchDailyWorkspaceUsage(
                auth,
                range.apiStartDate,
                range.apiEndDate,
                range.window,
                now)
            try Task.checkCancellation()
            if summary.isDisplayableCost { return summary }
            if let local { return local }
            return summary
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let local { return local }
            throw CostRangeQueryError.usageUnavailable
        }
    }

    private func beginCostProgress() {
        costProgressConsumers += 1
        if costProgressConsumers == 1 {
            publishCostProgress(.preparing, force: true)
        }
    }

    private func endCostProgress() {
        costProgressConsumers = max(0, costProgressConsumers - 1)
        if costProgressConsumers == 0 {
            publishCostProgress(.finished, force: true)
            // Idle shortly after so UI can clear loading chrome.
            costProgress.progress = .idle
        }
    }

    private func publishCostProgress(_ progress: CostScanProgress, force: Bool = false) {
        if force || progress.phase != costScanProgress.phase || progress.completedUnits != costScanProgress.completedUnits {
            costProgress.progress = progress
        }
    }

    private func storeDetailCostCache(_ summary: ApiEquivalentSummary, key: String) {
        // Do not pin failed/empty scans forever; empty ranges should re-query next visit.
        guard summary.isDisplayableCost else { return }
        if detailCostCache[key] == nil {
            detailCostCacheOrder.append(key)
        }
        detailCostCache[key] = summary
        while detailCostCacheOrder.count > Self.detailCostCacheLimit {
            let evicted = detailCostCacheOrder.removeFirst()
            detailCostCache.removeValue(forKey: evicted)
        }
    }

    private static func detailCacheKey(for range: ApiCostRange) -> String {
        "\(range.apiStartDate)|\(range.apiEndDate)|\(range.window.start.timeIntervalSince1970)|\(range.window.end.timeIntervalSince1970)"
    }

    private func loadValidAuth(preferCached: Bool) async throws -> CodexAuth {
        do {
            let auth = try await services.loadValidAuth(preferCached, latestAuth)
            let previousAccountId = accountIdentityKey(for: latestAuth)
            let nextAccountId = accountIdentityKey(for: auth)
            latestAuth = auth
            // Only attach quota plan when it belongs to the same account identity.
            // Otherwise a switch leaves the previous tier (e.g. Pro 5X) painted on Free.
            let planHint = (previousAccountId != nil && previousAccountId == nextAccountId)
                ? latestQuota?.plan
                : nil
            if previousAccountId != nextAccountId {
                clearAccountScopedState(keepingAuth: auth)
            } else {
                accountDisplay = CodexAccountDisplay.make(auth: auth, quotaPlan: planHint)
            }
            // Never write ~/.codex/auth.json from the poll path.
            // Official auth is only written by explicit switch, OAuth refresh (TokenRefresher + store),
            // or repair — otherwise mock/test auth or transient loads can wipe real credentials.
            //
            // Also never overwrite a *better* managed credential with a worse/unusable one
            // (this is how unit-test fixtures previously wiped ~/.codex-runway/accounts).
            if let activeAccountId, auth.loginUsability == .usable {
                let previous = try? accountStore.loadCredential(id: activeAccountId)
                let shouldMirror: Bool = {
                    guard let previous else { return true }
                    if previous == auth { return false }
                    // Keep existing usable credential if the incoming one is weaker.
                    if previous.loginUsability == .usable, auth.loginUsability != .usable {
                        return false
                    }
                    return true
                }()
                if shouldMirror, previous != auth {
                    try? accountStore.saveCredential(id: activeAccountId, auth: auth)
                }
                if var account = managedAccounts.first(where: { $0.id == activeAccountId }) {
                    account = account.withIdentity(from: auth, quotaPlan: planHint)
                    try? accountStore.updateMetadata(account)
                    reloadAccountIndex()
                }
            }
            return auth
        } catch RunwayModelAuthError.load(let error) {
            latestAuth = nil
            accountDisplay = CodexAccountDisplay.make(auth: nil, quotaPlan: nil)
            throw error
        }
    }

    /// Wipe meters / quota / credits that are bound to the previously active account.
    private func clearAccountScopedState(keepingAuth auth: CodexAuth?) {
        accountStateGeneration += 1
        latestQuota = nil
        latestResetCredits = nil
        latestCost = nil
        latestDisplayedCost = nil
        latestDisplayedCostRange = nil
        latestCurrentCycleFullWindow = nil
        lastCostRefreshCompletedAt = nil
        lastCostCycleIdentity = nil
        lastTokenHeatmapRefreshCompletedAt = nil
        detailCostCache = [:]
        detailCostCacheOrder = []
        tokenHeatmapAllDevicesTokens = [:]
        tokenHeatmapLocalTokens = [:]
        tokenHeatmapCalculatedAt = nil
        tokenHeatmapOfficialStatsAsOf = nil
        tokenHeatmapOfficialGeneratedAt = nil
        quotaMeters = []
        quotaLines = []
        resetCreditSummary = nil
        resetCreditDetails = []
        resetCreditLines = []
        costDetail = nil
        costText = l10n.text(.notScanned)
        costSubtitle = ""
        quotaText = l10n.text(.notLoaded)
        resetCreditsText = l10n.text(.notLoaded)
        statusText = l10n.text(.statusLogin)
        latestAuth = auth
        accountDisplay = CodexAccountDisplay.make(auth: auth, quotaPlan: nil)
    }

    private func accountIdentityKey(for auth: CodexAuth?) -> String? {
        guard let auth else { return nil }
        return AccountIdentity.matchKey(for: auth)
    }

    private func isCurrentAccount(_ auth: CodexAuth, generation: Int) -> Bool {
        generation == accountStateGeneration
            && accountIdentityKey(for: auth) == accountIdentityKey(for: latestAuth)
    }

    private func applyQuota(_ quota: QuotaSnapshot) {
        accountDisplay = CodexAccountDisplay.make(auth: latestAuth, quotaPlan: quota.plan)
        statusText = menuBarText(for: quota, now: quota.updatedAt)
        let unknown = l10n.text(.unknown)
        let primaryTitle = quotaWindowTitle(quota.primary)
        let secondary = quota.secondary.map { "\(l10n.text(.weeklyUsage)) \($0.usedPercent)%" } ?? "\(l10n.text(.weeklyUsage)) n/a"
        quotaText = "\(l10n.text(.plan)) \(quota.plan ?? unknown) · \(primaryTitle) \(quota.primary.usedPercent)% · \(secondary)"
        quotaMeters = quotaMeters(from: quota)
        quotaLines = [
            DetailLine(title: l10n.text(.plan), value: quota.plan ?? unknown),
            DetailLine(title: primaryTitle, value: windowText(quota.primary, now: quota.updatedAt)),
        ]
        if let secondary = quota.secondary {
            quotaLines.append(DetailLine(title: l10n.text(.weeklyUsage), value: windowText(secondary, now: quota.updatedAt)))
        }
        for extra in visibleAdditionalQuotaWindows(from: quota) {
            quotaLines.append(DetailLine(title: extra.name, value: windowText(extra.window, now: quota.updatedAt)))
        }
        if let balance = quota.creditsBalance {
            quotaLines.append(DetailLine(title: l10n.text(.creditsBalance), value: String(format: "%.2f", balance)))
        }
    }

    private func applyResetCredits(_ snapshot: ResetCreditsSnapshot) {
        let next = snapshot.credits
            .filter { $0.status == "available" }
            .compactMap(\.expiresAt)
            .min()
        latestResetCredits = snapshot
        resetCreditSummary = ResetCreditSummary(snapshot: snapshot)
        let suffix = next.map { " · \(l10n.text(.left)) \(duration($0.timeIntervalSince(snapshot.updatedAt)))" } ?? ""
        resetCreditsText = "\(snapshot.availableCount) \(l10n.text(.available)) / \(snapshot.credits.count) \(l10n.text(.total))\(suffix)"
        resetCreditLines = [
            DetailLine(title: l10n.text(.available), value: "\(snapshot.availableCount)"),
            DetailLine(title: l10n.text(.total), value: "\(snapshot.credits.count)"),
        ]
        resetCreditLines.append(contentsOf: snapshot.credits.prefix(6).enumerated().map { index, credit in
            let expiry = credit.expiresAt.map {
                "\(Self.displayDate($0)) · \(duration($0.timeIntervalSince(snapshot.updatedAt))) \(l10n.text(.left))"
            } ?? l10n.text(.noExpiry)
            return DetailLine(title: "\(l10n.text(.credit)) \(index + 1)", value: "\(localizedStatus(credit.status)) · \(expiry)")
        })
        resetCreditDetails = ResetCreditSummary.sortedByExpiry(snapshot.credits).enumerated().map { index, credit in
            let remaining = max(0, credit.remainingSeconds)
            let hasExpiry = credit.expiresAt != nil
            return ResetCreditDetail(
                id: credit.id ?? "\(index)",
                title: "\(l10n.text(.credit)) \(index + 1)",
                statusText: localizedStatus(credit.status),
                state: resetCreditState(credit),
                expiresAt: credit.expiresAt,
                remainingDuration: remaining,
                remainingProgress: hasExpiry ? min(1, remaining / (30 * 24 * 3_600)) : 1)
        }
    }

    private func scanCostAndHeatmap(
        _ quota: QuotaSnapshot,
        auth: CodexAuth,
        policy: UsageCostRefreshPolicy,
        includeCost: Bool,
        includeHeatmap: Bool
    ) async {
        let expectedGeneration = accountStateGeneration
        let now = Date()
        let range = settings.preferences.apiCostSummaryRange
        let currentWindows = currentCycleWindows(from: quota, now: now)
        latestCurrentCycleFullWindow = currentWindows?.full
        let selectedRange = selectedCostRange(for: range, fullWindow: currentWindows?.full, now: now)
        var queries: [ApiCostQuery] = []
        if includeCost {
            queries.append(contentsOf: costQueries(
                currentWindow: currentWindows?.elapsed,
                selectedRange: selectedRange))
        }
        let heatmapWindow = TokenUsageHeatmapBuilder.yearToDateWindow(now: now)
        if includeHeatmap {
            queries.append(ApiCostQuery(id: Self.tokenHeatmapQueryID, window: heatmapWindow))
        }
        guard !queries.isEmpty else { return }

        beginCostProgress()
        defer { endCostProgress() }
        publishCostProgress(.preparing, force: true)

        do {
            let local = try await localCostSummaries(queries: queries, now: now, policy: policy)
            if includeCost {
                let current = try await resolveCurrentCost(
                    window: currentWindows?.elapsed,
                    local: local[Self.currentCostQueryID],
                    auth: auth,
                    now: now)
                if let current {
                    applyCurrentCost(current)
                    if let elapsed = currentWindows?.elapsed {
                        storeDetailCostCache(current, key: Self.detailCacheKey(for: .range(window: elapsed)))
                    }
                }
                let summary = try await resolveDisplayedCost(
                    range: range,
                    selectedRange: selectedRange,
                    current: current,
                    local: local[Self.selectedCostQueryID],
                    auth: auth,
                    now: now)
                try Task.checkCancellation()
                applyDisplayedCost(summary, range: range, now: now)
                if let selectedRange {
                    storeDetailCostCache(summary, key: Self.detailCacheKey(for: selectedRange))
                }
            }
            if includeHeatmap {
                try Task.checkCancellation()
                let localMap = local[Self.tokenHeatmapQueryID].map(dailyTokenMap(from:)) ?? [:]
                guard isCurrentAccount(auth, generation: expectedGeneration) else {
                    throw CancellationError()
                }
                applyLocalTokenHeatmap(localMap, now: now)
                do {
                    try await fetchAndApplyProfileTokenHeatmap(TokenHeatmapRemoteRequest(
                        auth: auth,
                        localTokens: localMap,
                        calculatedAt: now,
                        accountGeneration: expectedGeneration))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = l10n.text(.tokenUsageHeatmapUnavailable)
                    if tokenHeatmapAllDevicesTokens.isEmpty, tokenHeatmapLocalTokens.isEmpty {
                        tokenHeatmapCalculatedAt = now
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if includeCost {
                let text = costQueryErrorText(error)
                if latestDisplayedCost != nil, latestDisplayedCostRange == range {
                    noteCostScanFailure(text)
                } else {
                    clearDisplayedCost(text)
                }
            }
            if includeHeatmap,
               tokenHeatmapAllDevicesTokens.isEmpty,
               tokenHeatmapLocalTokens.isEmpty
            {
                tokenHeatmapCalculatedAt = now
            }
            if includeHeatmap {
                lastError = l10n.text(.tokenUsageHeatmapUnavailable)
            }
        }
    }

    private func fetchAndApplyProfileTokenHeatmap(
        _ request: TokenHeatmapRemoteRequest
    ) async throws {
        publishCostProgress(.fetchingOnline, force: true)
        let profileUsage = try await services.fetchCodexProfileTokenUsage(request.auth)
        try Task.checkCancellation()
        guard isCurrentAccount(request.auth, generation: request.accountGeneration) else {
            throw CancellationError()
        }
        applyTokenHeatmap(
            allDevices: profileUsage.dailyTokens,
            local: request.localTokens,
            officialStatsAsOf: profileUsage.statsAsOf,
            officialGeneratedAt: profileUsage.generatedAt,
            now: request.calculatedAt)
    }

    private func finishFullRefresh(id: UUID) {
        guard activeFullRefreshID == id else { return }
        activeFullRefreshID = nil
        fullRefreshWork = nil
        isRefreshingAll = false
        onFullRefreshCompleted?()
    }

    private func finishTokenHeatmapRefresh(id: UUID) {
        guard activeTokenHeatmapRefreshID == id else { return }
        activeTokenHeatmapRefreshID = nil
        tokenHeatmapRefreshWork = nil
        refreshingSections.remove(.tokenHeatmap)
    }

    private func cancelAccountScopedRefreshes() async {
        if let id = activeFullRefreshID, let work = fullRefreshWork {
            work.cancel()
            await work.value
            finishFullRefresh(id: id)
        }
        if let id = activeTokenHeatmapRefreshID, let work = tokenHeatmapRefreshWork {
            work.cancel()
            await work.value
            finishTokenHeatmapRefresh(id: id)
        }
    }

    func cancelCodexRefreshesForProviderSwitch() {
        fullRefreshWork?.cancel()
        tokenHeatmapRefreshWork?.cancel()
    }

    private func localCostSummaries(
        queries: [ApiCostQuery],
        now: Date,
        policy: UsageCostRefreshPolicy
    ) async throws -> [String: ApiEquivalentSummary] {
        guard !queries.isEmpty else { return [:] }
        do {
            return try await services.scanAPIEquivalent(queries, now, policy, costProgressReporter)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return [:]
        }
    }

    private func resolveCurrentCost(
        window: DateInterval?,
        local: ApiEquivalentSummary?,
        auth: CodexAuth,
        now: Date
    ) async throws -> ApiEquivalentSummary? {
        guard let window else { return nil }
        do {
            return try await resolveCost(
                local: local,
                range: .range(window: window),
                auth: auth,
                now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func resolveDisplayedCost(
        range: ApiCostSummaryRange,
        selectedRange: ApiCostRange?,
        current: ApiEquivalentSummary?,
        local: ApiEquivalentSummary?,
        auth: CodexAuth,
        now: Date
    ) async throws -> ApiEquivalentSummary {
        if range == .current {
            // Empty-but-successful current cycle is still a valid summary ("no usage").
            // Only fail hard when we could not resolve any summary at all.
            guard let current else {
                throw CostRangeQueryError.usageUnavailable
            }
            return current
        }
        if range == .previous, current == nil {
            throw CostRangeQueryError.usageUnavailable
        }
        guard let selectedRange else { throw CostRangeQueryError.usageUnavailable }
        // Pass through zero-usage results so the UI can show "no usage in range"
        // instead of conflating that with a fetch/analytics failure.
        return try await resolveCost(local: local, range: selectedRange, auth: auth, now: now)
    }

    private func selectedCostRange(
        for range: ApiCostSummaryRange,
        fullWindow: DateInterval?,
        now: Date
    ) -> ApiCostRange? {
        switch range {
        case .current:
            return nil
        case .previous:
            return fullWindow.map { ApiCostRange.previousCycle(from: $0) }
        case .today:
            return .today(now: now)
        case .thisMonth:
            return .thisMonth(now: now)
        }
    }

    private func costQueries(
        currentWindow: DateInterval?,
        selectedRange: ApiCostRange?
    ) -> [ApiCostQuery] {
        var queries: [ApiCostQuery] = []
        if let currentWindow {
            queries.append(ApiCostQuery(id: Self.currentCostQueryID, window: currentWindow))
        }
        if let selectedRange {
            queries.append(ApiCostQuery(id: Self.selectedCostQueryID, window: selectedRange.window))
        }
        return queries
    }

    private func currentCycleWindows(from quota: QuotaSnapshot, now: Date) -> (full: DateInterval, elapsed: DateInterval)? {
        quota.cycleWindows(now: now)
    }

    private func applyCurrentCost(_ summary: ApiEquivalentSummary) {
        latestCost = summary
        costDetail = summary
        cacheCost(summary)
    }

    private func applyDisplayedCost(_ summary: ApiEquivalentSummary, range: ApiCostSummaryRange, now: Date = Date(), clearsScanNote: Bool = true) {
        if clearsScanNote { costScanNote = nil }
        latestDisplayedCost = summary
        latestDisplayedCostRange = range
        // Successful scan with zero tokens is "no usage", not a fetch failure.
        if !summary.isDisplayableCost {
            costText = l10n.text(.usageAnalyticsEmpty)
            costSubtitle = costSubtitle(for: summary, range: range, now: now)
            costLines = [
                DetailLine(title: l10n.text(.apiCost), value: l10n.text(.usageAnalyticsEmpty)),
                DetailLine(title: l10n.text(.apiCostSource), value: sourceText(summary.source)),
            ]
            if let costScanNote {
                costLines.append(DetailLine(title: l10n.text(.costScanFailed), value: costScanNote))
            }
            return
        }
        let amount = summary.estimatedUSD.map(DurationFormatter.money) ?? "--"
        costText = "\(amount) \(l10n.text(.apiEquivalent)) · \(Self.compactNumber(summary.totals.totalTokens)) \(l10n.text(.tokens)) · \(sourceText(summary.source))"
        costSubtitle = costSubtitle(for: summary, range: range, now: now)
        costLines = [
            DetailLine(title: l10n.text(.estimatedAPICost), value: amount),
            DetailLine(title: l10n.text(.tokens), value: Self.compactNumber(summary.totals.totalTokens)),
            DetailLine(title: l10n.text(.inputCachedOutput), value: "\(Self.compactNumber(summary.totals.uncachedInputTokens)) / \(Self.compactNumber(summary.totals.cachedInputTokens)) / \(Self.compactNumber(summary.totals.outputTokens))"),
            DetailLine(title: l10n.text(.turns), value: "\(summary.totals.turns)"),
            DetailLine(title: l10n.text(.apiCostSource), value: sourceText(summary.source)),
            DetailLine(title: l10n.text(.pricingVersion), value: summary.pricingVersion),
        ]
        if summary.source == .onlineAnalytics {
            costLines.append(DetailLine(title: l10n.text(.rawAnalyticsCredits), value: Self.creditText(summary.rawCredits)))
        }
        if let costScanNote {
            costLines.append(DetailLine(title: l10n.text(.costScanFailed), value: costScanNote))
        }
    }

    private func clearDisplayedCost(_ text: String) {
        latestDisplayedCost = nil
        latestDisplayedCostRange = nil
        costScanNote = nil
        costText = text
        costSubtitle = ""
        costLines = [DetailLine(title: l10n.text(.apiCost), value: text)]
    }

    private func cacheCost(_ summary: ApiEquivalentSummary) {
        guard summary.isDisplayableCost else { return }
        try? costCacheStore.save(summary)
    }

    private func noteCostScanFailure(_ text: String) {
        guard let latestDisplayedCost, let latestDisplayedCostRange else { return }
        costScanNote = text
        applyDisplayedCost(latestDisplayedCost, range: latestDisplayedCostRange, clearsScanNote: false)
    }

    private func costQueryErrorText(_ error: Error) -> String {
        if error is CostRangeQueryError {
            return l10n.text(.usageAnalyticsUnavailable)
        }
        return error.localizedDescription
    }

    private func costSubtitle(for summary: ApiEquivalentSummary, range: ApiCostSummaryRange, now: Date) -> String {
        let pricing = summary.confidence == .tokensOnly ? l10n.text(.tokensOnly) : l10n.text(.apiTokenPricing)
        // Minute granularity so tick()'s equality guard suppresses per-second
        // subtitle writes (each write re-layouts the whole panel).
        let calculated = DurationFormatter.relativePast(
            since: summary.calculatedAt,
            now: now,
            language: l10n.language,
            includeSeconds: false)
        return "\(costRangeText(range)) · \(pricing) · \(summary.totals.turns) \(l10n.text(.turns)) · \(l10n.text(.calculatedAt)) \(calculated)"
    }

    private func costRangeText(_ range: ApiCostSummaryRange) -> String {
        switch range {
        case .today:
            return l10n.text(.today)
        case .current:
            return l10n.text(.currentCycle)
        case .previous:
            return l10n.text(.previousCycle)
        case .thisMonth:
            return l10n.text(.thisMonth)
        }
    }

    private func windowText(_ window: RateWindow, now: Date) -> String {
        let reset = window.resetsAt.map { " · \(l10n.text(.resetsIn)) \(duration($0.timeIntervalSince(now)))" } ?? ""
        return "\(window.usedPercent)% \(l10n.text(.used))\(reset)"
    }

    private func quotaMeters(from quota: QuotaSnapshot) -> [QuotaMeter] {
        var meters = [
            QuotaMeter(title: quotaWindowTitle(quota.primary), window: quota.primary, now: quota.updatedAt, markerPercents: [20, 50, 80]),
        ]
        if let secondary = quota.secondary {
            meters.append(QuotaMeter(title: l10n.text(.weeklyUsage), window: secondary, now: quota.updatedAt, markerPercents: [20, 50, 80]))
        }
        meters.append(contentsOf: visibleAdditionalQuotaWindows(from: quota).map {
            QuotaMeter(
                title: $0.name,
                window: $0.window,
                now: quota.updatedAt,
                markerPercents: [20, 50, 80],
                source: .modelSpecific)
        })
        return meters
    }

    private func visibleAdditionalQuotaWindows(from quota: QuotaSnapshot) -> [NamedRateWindow] {
        settings.preferences.showsModelSpecificQuotaUsage ? quota.additionalWindows : []
    }

    private func quotaWindowTitle(_ window: RateWindow) -> String {
        switch window.windowMinutes {
        case 300:
            return l10n.text(.fiveHourUsage)
        case 10_080:
            return l10n.text(.weeklyUsage)
        default:
            return l10n.text(.quota)
        }
    }

    private func localizedStatus(_ status: String) -> String {
        switch status {
        case "available":
            return l10n.text(.statusAvailable)
        case "used":
            return l10n.text(.statusUsed)
        default:
            return l10n.text(.statusUnknown)
        }
    }

    private func sessionStateText(_ state: SessionActivityState) -> String {
        switch state {
        case .recent:
            return l10n.text(.recent)
        case .needsAttention:
            return l10n.text(.needsAttention)
        case .failed:
            return l10n.text(.failed)
        }
    }

    private func resetCreditState(_ credit: ResetCredit) -> ResetCreditState {
        guard credit.status == "available" else { return .unavailable }
        guard credit.expiresAt != nil else { return .available }
        if credit.remainingSeconds <= 7 * 24 * 3_600 { return .expiring }
        return .available
    }

    private func menuBarText(for quota: QuotaSnapshot, now: Date) -> String {
        guard let reset = quota.primary.resetsAt else {
            return quota.primary.usedPercent >= 100 ? l10n.text(.statusWait) : "\(quota.primary.usedPercent)%"
        }
        let text = duration(reset.timeIntervalSince(now), includeSeconds: false)
        return quota.primary.usedPercent >= 100 ? "\(l10n.text(.statusWait)) \(text)" : text
    }

    private func duration(_ seconds: TimeInterval, includeSeconds: Bool = true) -> String {
        DurationFormatter.localized(seconds, language: l10n.language, includeSeconds: includeSeconds)
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func displayDateString(_ value: String) -> String {
        guard let date = apiDateFormatter.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func creditText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func sourceText(_ source: ApiEquivalentSource) -> String {
        switch source {
        case .localSessions:
            return l10n.text(.sourceLocalSessions)
        case .onlineAnalytics:
            return l10n.text(.sourceOnlineSupplement)
        case .unavailable:
            // Source is "unavailable" when a range resolved with zero tokens — not a hard failure.
            return l10n.text(.usageAnalyticsEmpty)
        }
    }

    static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.2fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private static let apiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
