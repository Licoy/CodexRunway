import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Runway provider routing")
@MainActor
struct RunwayModelProviderTests {
    @Test("provider selection is persisted")
    func providerSelectionIsPersisted() {
        let suite = "RunwayModelProviderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        let settings = RunwaySettings(store: store)
        let accountStore = isolatedAccountStore()
        let model = RunwayModel(
            settings: settings,
            services: testServices(),
            accountStore: accountStore)

        #expect(model.selectedProvider == .codex)

        model.selectProvider(.grok)

        #expect(model.selectedProvider == .grok)
        #expect(settings.preferences.selectedProvider == .grok)
        #expect(store.load().selectedProvider == .grok)
    }

    @Test("selected Grok provider projects its cached identity and quota")
    func selectedGrokProjectsCachedState() async throws {
        let fixture = try GrokModelFixture(cachedPercent: 17.5)
        defer { fixture.remove() }
        let settings = runwaySettings(selectedProvider: .grok)
        let module = GrokAccountModule(
            store: fixture.store,
            cli: fixture.cli,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let model = RunwayModel(
            settings: settings,
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokModule: module,
            grokCLIAvailable: true)

        try await waitUntil { model.grokPanelState.quota != nil }

        #expect(model.selectedProvider == .grok)
        #expect(model.selectedAccountDisplayName == "grok@example.com")
        #expect(model.selectedQuotaMeters.first?.usedPercent == 18)
        #expect(model.selectedQuotaText.contains("SuperGrok"))
        #expect(model.selectedQuotaLines.contains { $0.value.contains("SuperGrok") })
    }

    @Test("switching providers rejects a late Grok refresh result")
    func providerSwitchRejectsLateGrokRefresh() async throws {
        let fixture = try GrokModelFixture(cachedPercent: 17.5)
        defer { fixture.remove() }
        let blocker = BlockingGrokBilling(snapshot: fixture.quota(percent: 88))
        let cli = GrokCLIClient(
            billing: { _ in try await blocker.fetch() },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
        let module = GrokAccountModule(
            store: fixture.store,
            cli: cli,
            runningProcessIDs: { [] },
            now: { fixture.now })
        let model = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokModule: module,
            grokCLIAvailable: true)
        try await waitUntil { model.grokPanelState.quota != nil }
        var completionCount = 0
        model.onFullRefreshCompleted = { completionCount += 1 }

        model.refresh()
        await blocker.waitUntilStarted()
        model.selectProvider(.codex)
        #expect(completionCount == 1)
        model.onFullRefreshCompleted = nil
        await blocker.release()
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.selectedProvider == .codex)
        #expect(!model.isRefreshingGrok)
        #expect(model.selectedQuotaMeters == model.quotaMeters)
        #expect(model.grokPanelState.quota?.meters.first?.usedPercent == 18)
    }

    @Test("scheduled Grok refresh completes the shared refresh lifecycle")
    func scheduledGrokRefreshCompletesLifecycle() async throws {
        let fixture = try GrokModelFixture(cachedPercent: 17.5)
        defer { fixture.remove() }
        let model = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokModule: GrokAccountModule(
                store: fixture.store,
                cli: fixture.cli,
                runningProcessIDs: { [] },
                now: { fixture.now }),
            grokCLIAvailable: true)
        try await waitUntil { model.grokPanelState.quota != nil }
        var completionCount = 0
        model.onFullRefreshCompleted = { completionCount += 1 }

        model.refresh()

        try await waitUntil { completionCount == 1 }
        #expect(!model.isRefreshingGrok)
        #expect(completionCount == 1)
    }

    @Test("unavailable Grok refresh still completes the shared refresh lifecycle")
    func unavailableGrokRefreshCompletesLifecycle() {
        let model = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokCLIAvailable: false)
        var completionCount = 0
        model.onFullRefreshCompleted = { completionCount += 1 }

        model.refresh()

        #expect(completionCount == 1)
        #expect(model.grokPanelState.availability == .cliUnavailable)
    }

    @Test("selected Grok provider does not trigger Codex reset-today work")
    func selectedGrokDoesNotRefreshCodexResetToday() async throws {
        let counter = InvocationCounter()
        var services = testServices()
        services.fetchRateLimitResetToday = {
            await counter.increment()
            throw URLError(.badServerResponse)
        }
        let model = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: services,
            accountStore: isolatedAccountStore(),
            grokCLIAvailable: false)

        model.tick()
        model.relabel()
        try await Task.sleep(for: .milliseconds(50))

        let invocationCount = await counter.value
        #expect(invocationCount == 0)
    }

    @Test("Grok keeps distinct CLI-missing and signed-out states")
    func grokAvailabilityStatesRemainDistinct() async throws {
        let unavailable = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokCLIAvailable: false)
        #expect(unavailable.grokPanelState.availability == .cliUnavailable)

        let fixture = try GrokModelFixture(cachedPercent: nil)
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.store.officialAuthURL)
        let signedOut = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokModule: GrokAccountModule(
                store: fixture.store,
                cli: fixture.cli,
                runningProcessIDs: { [] },
                now: { fixture.now }),
            grokCLIAvailable: true)

        try await waitUntil { signedOut.grokPanelState.availability != .loading }

        #expect(signedOut.grokPanelState.availability == .notLoggedIn)
    }

    @Test("Grok authentication and billing schema failures remain distinct")
    func grokRefreshFailuresRemainDistinct() async throws {
        let authenticationFixture = try GrokModelFixture(cachedPercent: nil)
        defer { authenticationFixture.remove() }
        let authenticationModel = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokModule: GrokAccountModule(
                store: authenticationFixture.store,
                cli: GrokCLIClient(
                    billing: { _ in throw GrokCLIError.authenticationRequired },
                    loginOAuth: { _ in },
                    version: { "grok 0.2.114" }),
                runningProcessIDs: { [] },
                now: { authenticationFixture.now }),
            grokCLIAvailable: true)

        try await waitUntil {
            authenticationModel.grokPanelState.availability == .reauthenticationRequired
        }

        let parsingFixture = try GrokModelFixture(cachedPercent: nil)
        defer { parsingFixture.remove() }
        let parsingModel = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokModule: GrokAccountModule(
                store: parsingFixture.store,
                cli: GrokCLIClient(
                    billing: { _ in throw GrokBillingDecodingError.unknownStructure },
                    loginOAuth: { _ in },
                    version: { "grok 0.2.114" }),
                runningProcessIDs: { [] },
                now: { parsingFixture.now }),
            grokCLIAvailable: true)

        try await waitUntil {
            parsingModel.grokPanelState.availability == .billingParseFailed
        }
    }

    @Test("cached Grok refresh failures survive identity reconciliation")
    func cachedGrokRefreshFailureSurvivesReconciliation() async throws {
        let fixture = try GrokModelFixture(cachedPercent: 17.5)
        defer { fixture.remove() }
        var index = try fixture.store.loadIndex()
        let currentID = try #require(index.currentAccountID)
        var account = try #require(index.account(id: currentID))
        account.lastError = "authentication_required"
        account.requiresReauth = true
        index.upsert(account)
        try fixture.store.saveIndex(index)
        let model = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokModule: GrokAccountModule(
                store: fixture.store,
                cli: fixture.cli,
                runningProcessIDs: { [] },
                now: { fixture.now }),
            grokCLIAvailable: true)

        try await waitUntil { model.grokPanelState.quota != nil }

        #expect(model.grokPanelState.availability == .reauthenticationRequired)
        #expect(model.grokLastError == model.l10n.text(.grokReauthenticationRequired))
        #expect(model.grokAccountState.accounts.first { $0.id == currentID }?.lastError
            == "authentication_required")
    }

    @Test("switching a Grok account invalidates its prior refresh")
    func switchGrokAccountInvalidatesPriorRefresh() async throws {
        let fixture = try GrokModelFixture(cachedPercent: 17.5)
        defer { fixture.remove() }
        let blocker = BlockingGrokBilling(snapshot: fixture.quota(percent: 88))
        let model = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokModule: GrokAccountModule(
                store: fixture.store,
                cli: GrokCLIClient(
                    billing: { _ in try await blocker.fetch() },
                    loginOAuth: { _ in },
                    version: { "grok 0.2.114" }),
                runningProcessIDs: { [] },
                now: { fixture.now }),
            grokCLIAvailable: true)
        try await waitUntil { model.grokPanelState.quota != nil }
        let currentID = try #require(model.grokAccountState.currentAccountID)

        model.refreshGrok(.current)
        await blocker.waitUntilStarted()
        model.switchGrokAccount(id: currentID)

        #expect(!model.isRefreshingGrok)
        await blocker.release()
        try await waitUntil { !model.isGrokAccountOperationInProgress }
        // Switch success triggers a fresh current-account billing pull.
        try await waitUntil {
            !model.isRefreshingGrok
                && model.grokPanelState.quota?.meters.first?.usedPercent == 88
        }
        #expect(model.grokPanelState.quota?.meters.first?.usedPercent == 88)
    }

    @Test("refresh-all sibling billing failures do not cover the current panel")
    func refreshAllSiblingFailureDoesNotCoverPanel() async throws {
        let fixture = try GrokModelFixture(cachedPercent: 17.5)
        defer { fixture.remove() }
        let second = try fixture.store.upsertCredentialData(
            GrokModelFixture.credential(
                email: "sibling@example.com",
                userID: "sibling-grok-user"),
            makeCurrent: false,
            now: fixture.now)
        let currentID = try #require(try fixture.store.loadIndex().currentAccountID)
        let currentHome = fixture.store.officialHomeURL
        let siblingHome = fixture.store.accountDirectory(id: second.id)
        let model = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokModule: GrokAccountModule(
                store: fixture.store,
                cli: GrokCLIClient(
                    billing: { homeURL in
                        if homeURL == siblingHome {
                            throw GrokBillingDecodingError.unknownStructure
                        }
                        if homeURL == currentHome {
                            return fixture.quota(percent: 41)
                        }
                        return fixture.quota(percent: 41)
                    },
                    loginOAuth: { _ in },
                    version: { "grok 0.2.114" }),
                runningProcessIDs: { [] },
                now: { fixture.now }),
            grokCLIAvailable: true)

        try await waitUntil { model.grokPanelState.quota != nil }
        model.refreshGrok(.all)
        try await waitUntil { !model.isRefreshingGrok }

        #expect(model.grokPanelState.quota?.meters.first?.usedPercent == 41)
        #expect(model.grokPanelState.availability == .ready)
        #expect(model.grokLastError == nil)
        #expect(model.grokAccountState.accounts.first { $0.id == second.id }?.lastError
            == "billing_parse_failed")
        #expect(model.grokAccountState.accounts.first { $0.id == currentID }?.lastError == nil)
    }

    @Test("external Grok identity warning stays until a successful identity command")
    func externalGrokIdentityWarningIsSticky() async throws {
        let fixture = try GrokModelFixture(cachedPercent: 17.5)
        defer { fixture.remove() }
        let module = GrokAccountModule(
            store: fixture.store,
            cli: fixture.cli,
            runningProcessIDs: { [] },
            now: { fixture.now })
        _ = try await module.load()
        let second = try fixture.store.upsertCredentialData(
            GrokModelFixture.credential(
                email: "second@example.com",
                userID: "second-grok-user"),
            makeCurrent: false,
            now: fixture.now)
        _ = try await module.apply(.makeCurrent(id: second.id, allowWhileRunning: true))
        try fixture.initialCredential.write(to: fixture.store.officialAuthURL, options: .atomic)

        let model = RunwayModel(
            settings: runwaySettings(selectedProvider: .grok),
            services: testServices(),
            accountStore: isolatedAccountStore(),
            grokModule: module,
            grokCLIAvailable: true)

        try await waitUntil { model.grokPanelState.externalLoginChanged }
        #expect(model.grokAccountOperationMessage == model.l10n.text(.grokExternalLoginChanged))

        let rolledBackID = try #require(model.grokAccountState.currentAccountID)
        _ = try await module.apply(.setAlias(id: rolledBackID, alias: "Reloaded account"))
        model.bootstrapGrokAccounts()
        try await waitUntil { model.grokPanelState.identityName == "Reloaded account" }
        #expect(model.grokPanelState.externalLoginChanged)

        model.refreshGrok(.current)
        try await waitUntil {
            !model.isRefreshingGrok
                && model.grokPanelState.quota?.meters.first?.usedPercent == 42
        }
        #expect(model.grokPanelState.externalLoginChanged)
        #expect(model.grokAccountOperationMessage == model.l10n.text(.grokExternalLoginChanged))

        model.switchGrokAccount(id: second.id)
        try await waitUntil { !model.isGrokAccountOperationInProgress }
        #expect(!model.grokPanelState.externalLoginChanged)
        #expect(model.grokAccountOperationMessage == model.l10n.text(.grokSwitchOnlyNewSessions))
        model.rebuildGrokPanelState()
        #expect(!model.grokPanelState.externalLoginChanged)
    }

    private func testServices() -> RunwayModelServices {
        RunwayModelServices(
            loadValidAuth: { _, _ in throw URLError(.userAuthenticationRequired) },
            fetchQuota: { _ in throw URLError(.badServerResponse) },
            fetchResetCredits: { _ in throw URLError(.badServerResponse) },
            fetchRateLimitResetToday: { throw URLError(.badServerResponse) },
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
    }

    private func isolatedAccountStore() -> AccountStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runway-provider-test-\(UUID().uuidString)", isDirectory: true)
        return AccountStore(
            rootURL: root.appendingPathComponent("accounts", isDirectory: true),
            officialAuthURL: root.appendingPathComponent("official-auth.json"))
    }

    private func runwaySettings(selectedProvider: RunwayProvider) -> RunwaySettings {
        let suite = "RunwayModelProviderSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = RunwaySettings(store: PreferencesStore(defaults: defaults))
        settings.updateSelectedProvider(selectedProvider)
        return settings
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for provider state.")
    }
}

private actor InvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor BlockingGrokBilling {
    private let snapshot: GrokQuotaSnapshot
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(snapshot: GrokQuotaSnapshot) {
        self.snapshot = snapshot
    }

    func fetch() async throws -> GrokQuotaSnapshot {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return snapshot
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct GrokModelFixture {
    let root: URL
    let store: GrokAccountStore
    let now = Date(timeIntervalSince1970: 1_785_499_200)
    let initialCredential: Data

    init(cachedPercent: Double?) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-model-tests-\(UUID().uuidString)", isDirectory: true)
        let officialHome = root.appendingPathComponent("official", isDirectory: true)
        try FileManager.default.createDirectory(at: officialHome, withIntermediateDirectories: true)
        store = GrokAccountStore(
            rootURL: root.appendingPathComponent("accounts", isDirectory: true),
            officialHomeURL: officialHome)
        let data = Self.credential()
        initialCredential = data
        try data.write(to: store.officialAuthURL)
        var account = try store.upsertCredentialData(data, makeCurrent: true, now: now)
        if let cachedPercent {
            account = account.applying(snapshot: quota(percent: cachedPercent))
            try store.updateMetadata(account)
        }
    }

    var cli: GrokCLIClient {
        GrokCLIClient(
            billing: { _ in quota(percent: 42.25) },
            loginOAuth: { _ in },
            version: { "grok 0.2.114" })
    }

    func quota(percent: Double) -> GrokQuotaSnapshot {
        GrokQuotaSnapshot(
            plan: "SuperGrok",
            includedUsagePercent: percent,
            period: GrokQuotaPeriod(
                kind: .weekly,
                startsAt: now,
                resetsAt: now.addingTimeInterval(7 * 24 * 3_600)),
            prepaidBalanceCents: 500,
            onDemandEnabled: true,
            onDemandUsedCents: 25,
            onDemandLimitCents: 1_000,
            source: .current,
            updatedAt: now)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func credential(
        email: String = "grok@example.com",
        userID: String = "grok-user"
    ) -> Data {
        Data(
            """
            {
              "https://auth.x.ai::desktop-client": {
                "auth_mode": "oidc",
                "email": "\(email)",
                "expires_at": "2099-08-01T12:00:00Z",
                "key": "access-token-for-\(userID)-tests-only",
                "oidc_client_id": "desktop-client",
                "oidc_issuer": "https://auth.x.ai",
                "principal_id": "principal-\(userID)",
                "principal_type": "User",
                "refresh_token": "refresh-token-for-\(userID)-tests-only",
                "user_id": "\(userID)"
              }
            }
            """.utf8)
    }
}
