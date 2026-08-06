import CodexRunwayCore
import Foundation

@MainActor
extension RunwayModel {
    var grokSidebarAccounts: [GrokManagedAccount] {
        var accounts = grokAccountState.accounts.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.resolvedDisplayName.localizedCaseInsensitiveCompare($1.resolvedDisplayName) == .orderedAscending
        }
        if let currentID = grokAccountState.currentAccountID,
           let currentIndex = accounts.firstIndex(where: { $0.id == currentID })
        {
            let current = accounts.remove(at: currentIndex)
            accounts.insert(current, at: 0)
        }
        return accounts
    }

    var selectedStatusText: String {
        if settings.preferences.statusBarProviderScope == .both {
            // Prefer Codex countdown when dual; fall back to Grok.
            if !quotaMeters.isEmpty, !statusText.isEmpty {
                return statusText
            }
            return grokStatusText
        }
        switch selectedProvider {
        case .codex:
            return statusText
        case .grok:
            return grokStatusText
        }
    }

    private var grokStatusText: String {
        guard let meter = grokPanelState.quota?.meters.first else {
            switch grokPanelState.availability {
            case .notLoggedIn, .reauthenticationRequired:
                return l10n.text(.statusLogin)
            case .loading:
                return l10n.text(.statusWait)
            case .ready:
                return l10n.text(.statusUnknown)
            case .cliUnavailable, .cliTooOld, .billingParseFailed, .failed:
                return l10n.text(.statusError)
            }
        }
        if let resetsAt = meter.resetsAt {
            return DurationFormatter.localized(
                resetsAt.timeIntervalSince(Date()),
                language: l10n.language,
                includeSeconds: false)
        }
        return "\(meter.remainingPercent)%"
    }

    var selectedQuotaMeters: [QuotaMeter] {
        switch settings.preferences.statusBarProviderScope {
        case .both:
            return StatusBarMeterSelection.dualProviderMeters(
                codexMeters: quotaMeters,
                grokMeters: grokPanelState.quota?.meters ?? [],
                codexLabel: l10n.text(.providerCodex),
                grokLabel: l10n.text(.providerGrok),
                l10n: l10n)
        case .selected:
            // Status bar keeps the overall included-quota meter; product breakdown is panel-only.
            // Grok panel titles are long ("周度包含额度"); menu bar uses Codex-style short windows.
            if selectedProvider == .codex {
                return quotaMeters
            }
            return Array((grokPanelState.quota?.meters ?? []).prefix(1)).map {
                StatusBarMeterSelection.withShortStatusBarTitle($0, l10n: l10n)
            }
        }
    }

    /// True when the status bar (or panel) needs a fresh Grok quota snapshot.
    var needsGrokStatusBarData: Bool {
        settings.preferences.statusBarProviderScope == .both
            || selectedProvider == .grok
            || widgetRequirements.contains(.providerQuota)
            || widgetRequirements.contains(.tokenTrend)
            || widgetRequirements.contains(.cost)
    }

    /// True when the status bar (or panel) needs a fresh Codex quota snapshot.
    var needsCodexStatusBarData: Bool {
        settings.preferences.statusBarProviderScope == .both
            || selectedProvider == .codex
            || widgetRequirements.contains(.providerQuota)
            || widgetRequirements.contains(.tokenTrend)
            || widgetRequirements.contains(.cost)
    }

    var selectedQuotaText: String {
        guard selectedProvider == .grok else { return quotaText }
        guard let quota = grokPanelState.quota, let meter = quota.meters.first else {
            return grokAvailabilityText(grokPanelState.availability)
        }
        return "\(quota.plan) · \(meter.title) \(meter.usedPercent)%"
    }

    var selectedQuotaLines: [DetailLine] {
        guard selectedProvider == .grok else { return quotaLines }
        return (grokPanelState.quota?.lines ?? []).map {
            DetailLine(title: $0.title, value: $0.value)
        }
    }

    var selectedAccountDisplayName: String {
        switch selectedProvider {
        case .codex:
            if !accountDisplay.displayName.isEmpty { return accountDisplay.displayName }
            return accountDisplay.isAuthenticated ? l10n.text(.unknownAccount) : l10n.text(.notLoggedIn)
        case .grok:
            return grokPanelState.identityName ?? l10n.text(.grokNotLoggedIn)
        }
    }

    var selectedAccountOperationMessage: String? {
        selectedProvider == .codex ? accountOperationMessage : grokAccountOperationMessage
    }

    var selectedLastError: String? {
        selectedProvider == .codex ? lastError : grokLastError
    }

    var isRefreshingSelectedAccountQuotas: Bool {
        selectedProvider == .codex ? isRefreshingAccountQuotas : isRefreshingGrok
    }

    func bootstrapGrokAccounts() {
        guard let grokModule else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await grokModule.load()
                applyGrokAccountState(state)
                if needsGrokStatusBarData,
                   grokCLIAvailable,
                   state.currentAccountID != nil,
                   grokPanelState.quota == nil
                {
                    refreshGrok(.current)
                }
                if selectedProvider == .grok
                    || widgetRequirements.contains(.tokenTrend)
                    || widgetRequirements.contains(.cost)
                {
                    refreshGrokLocalUsage()
                }
            } catch {
                grokLastError = grokErrorText(error)
                grokPanelState.availability = grokAvailability(for: error)
            }
        }
    }

    func providerDidChange(from previous: RunwayProvider) {
        if previous == .grok {
            cancelGrokRefresh()
            cancelGrokLocalUsageRefresh()
        }
        switch selectedProvider {
        case .codex:
            refresh(policy: .ifChanged)
        case .grok:
            cancelCodexRefreshesForProviderSwitch()
            rebuildGrokPanelState()
            if grokPanelState.quota == nil, grokModule != nil, grokCLIAvailable {
                refreshGrok(.current)
            }
            refreshGrokLocalUsage()
        }
    }

    func refreshGrokLocalUsage() {
        guard selectedProvider == .grok
            || widgetRequirements.contains(.tokenTrend)
            || widgetRequirements.contains(.cost)
        else { return }
        grokLocalUsageGeneration += 1
        let generation = grokLocalUsageGeneration
        grokPanelState.isRefreshingLocalUsage = true
        grokLocalUsageWork?.cancel()
        let costWindow = grokDefaultCostWindow()
        let work = Task { [weak self] in
            guard let self else { return }
            let summary: GrokLocalUsageSummary?
            do {
                summary = try await Task.detached(priority: .utility) {
                    try GrokSessionScanner().scan(
                        recentLimit: 5,
                        sessionLimit: 300,
                        costWindow: costWindow)
                }.value
            } catch is CancellationError {
                return
            } catch {
                summary = nil
            }
            guard generation == grokLocalUsageGeneration else { return }
            applyGrokLocalUsage(summary)
            grokPanelState.isRefreshingLocalUsage = false
            grokLocalUsageWork = nil
        }
        grokLocalUsageWork = work
    }

    private func cancelGrokLocalUsageRefresh() {
        grokLocalUsageGeneration += 1
        grokLocalUsageWork?.cancel()
        grokLocalUsageWork = nil
        grokPanelState.isRefreshingLocalUsage = false
    }

    private func grokDefaultCostWindow(now: Date = Date()) -> DateInterval {
        if let period = grokAccountState.accounts
            .first(where: { $0.id == grokAccountState.currentAccountID })?
            .cachedQuota?.period,
           let start = period.startsAt,
           let end = period.resetsAt,
           end > start
        {
            return DateInterval(start: start, end: min(now, end))
        }
        switch settings.preferences.apiCostSummaryRange {
        case .today:
            return ApiCostRange.today(now: now).window
        case .thisMonth:
            return ApiCostRange.thisMonth(now: now).window
        case .previous:
            let week: TimeInterval = 7 * 24 * 3_600
            let currentStart = now.addingTimeInterval(-week)
            return DateInterval(start: currentStart.addingTimeInterval(-week), end: currentStart)
        case .current:
            let week: TimeInterval = 7 * 24 * 3_600
            return DateInterval(start: now.addingTimeInterval(-week), end: now)
        }
    }

    private func applyGrokLocalUsage(_ summary: GrokLocalUsageSummary?) {
        grokPanelState.localUsage = summary
        if let summary {
            if grokTokenHeatmapLocalTokens != summary.dailyTokens {
                grokTokenHeatmapLocalTokens = summary.dailyTokens
            }
            grokTokenHeatmapCalculatedAt = summary.calculatedAt
            grokCostDetail = summary.costSummary
            applyGrokDisplayedCost(summary.costSummary)
        } else {
            grokTokenHeatmapLocalTokens = [:]
            grokTokenHeatmapCalculatedAt = nil
            grokCostDetail = nil
            grokCostText = l10n.text(.notScanned)
            grokCostSubtitle = ""
        }
    }

    private func applyGrokDisplayedCost(_ summary: ApiEquivalentSummary, now: Date = Date()) {
        let range = settings.preferences.apiCostSummaryRange
        if !summary.isDisplayableCost {
            grokCostText = l10n.text(.usageAnalyticsEmpty)
            grokCostSubtitle = grokCostSubtitle(for: summary, range: range, now: now)
            return
        }
        let amount = summary.estimatedUSD.map(DurationFormatter.money) ?? "--"
        grokCostText =
            "\(amount) \(l10n.text(.apiEquivalent)) · \(Self.compactNumber(summary.totals.totalTokens)) \(l10n.text(.tokens)) · \(l10n.text(.grokSourceLocalSessions))"
        grokCostSubtitle = grokCostSubtitle(for: summary, range: range, now: now)
    }

    private func grokCostSubtitle(
        for summary: ApiEquivalentSummary,
        range: ApiCostSummaryRange,
        now: Date
    ) -> String {
        let pricing = summary.confidence == .tokensOnly
            ? l10n.text(.tokensOnly)
            : l10n.text(.apiTokenPricing)
        let calculated = DurationFormatter.relativePast(
            since: summary.calculatedAt,
            now: now,
            language: l10n.language,
            includeSeconds: false)
        let rangeText: String
        switch range {
        case .today: rangeText = l10n.text(.today)
        case .current: rangeText = l10n.text(.currentCycle)
        case .previous: rangeText = l10n.text(.previousCycle)
        case .thisMonth: rangeText = l10n.text(.thisMonth)
        }
        return "\(rangeText) · \(pricing) · \(summary.totals.turns) \(l10n.text(.turns)) · \(l10n.text(.calculatedAt)) \(calculated)"
    }

    func refreshGrok(
        _ target: GrokRefreshTarget,
        completesFullRefresh: Bool = false
    ) {
        guard let grokModule else {
            grokPanelState.availability = .cliUnavailable
            if completesFullRefresh { onFullRefreshCompleted?() }
            return
        }
        guard grokCLIAvailable else {
            grokPanelState.availability = .cliUnavailable
            grokLastError = l10n.text(.grokCLIUnavailable)
            if completesFullRefresh { onFullRefreshCompleted?() }
            return
        }
        guard !isRefreshingGrok else {
            if completesFullRefresh, !grokRefreshCompletesFullRefresh {
                onFullRefreshCompleted?()
            }
            return
        }

        grokRefreshGeneration += 1
        let generation = grokRefreshGeneration
        grokRefreshCompletesFullRefresh = completesFullRefresh
        isRefreshingGrok = true
        grokRefreshingAccountIDs = grokRefreshIDs(target)
        if grokPanelState.quota == nil {
            grokPanelState.availability = .loading
        }
        let work = Task { [weak self] in
            guard let self else { return }
            let report = await grokModule.refresh(target)
            guard generation == grokRefreshGeneration else { return }
            do {
                let state = try await grokModule.load()
                guard generation == grokRefreshGeneration else { return }
                applyGrokAccountState(state)
                applyGrokRefreshReport(report)
            } catch {
                guard generation == grokRefreshGeneration else { return }
                grokLastError = grokErrorText(error)
                grokPanelState.availability = grokAvailability(for: error)
            }
            finishGrokRefresh(generation: generation)
            if selectedProvider == .grok
                || widgetRequirements.contains(.tokenTrend)
                || widgetRequirements.contains(.cost)
            {
                refreshGrokLocalUsage()
            }
        }
        grokRefreshWork = work
    }

    func refreshAllGrokAccountQuotas() {
        refreshGrok(.all)
    }

    func refreshGrokAccountQuota(id: String) {
        refreshGrok(.account(id: id))
    }

    func isRefreshingGrokAccount(id: String) -> Bool {
        grokRefreshingAccountIDs.contains(id)
    }

    func startGrokOAuthLogin() {
        runGrokCommand(.loginOAuth, message: l10n.text(.grokLoginWaiting))
    }

    func cancelGrokOAuthLogin() {
        grokAccountOperationWork?.cancel()
    }

    func importOfficialGrokAccount() {
        runGrokCommand(.importOfficial, message: l10n.text(.grokLoginWaiting))
    }

    /// Parse Grok transfer packs / credential files into a selectable preview (no writes).
    func previewGrokAccountImport(urls: [URL]) async -> GrokAccountImportPreview {
        guard let grokModule else {
            return GrokAccountImportPreview(failures: ["no_credentials"])
        }
        return await grokModule.previewImportFiles(at: urls)
    }

    /// Commit selected Grok import preview rows.
    @discardableResult
    func commitGrokAccountImport(
        candidates: [GrokAccountImportCandidate],
        selectedIDs: Set<String>) async -> Bool
    {
        guard let grokModule, !isGrokAccountOperationInProgress else { return false }
        isGrokAccountOperationInProgress = true
        grokAccountOperationMessage = l10n.text(.grokLoginWaiting)
        grokLastError = nil
        defer {
            isGrokAccountOperationInProgress = false
            grokAccountOperationWork = nil
        }
        do {
            let (batch, state) = try await grokModule.importPreviewSelection(
                candidates,
                selectedIDs: selectedIDs)
            applyGrokAccountState(state)
            if batch.successCount > 0 {
                grokAccountState.officialIdentityChangedExternally = false
                grokPanelState.externalLoginChanged = false
                grokAccountOperationMessage = String(
                    format: l10n.text(.accountsImportSucceeded),
                    batch.successCount)
                if batch.failureCount > 0 {
                    grokLastError = "\(l10n.text(.accountsImportFailed)): \(humanizeGrokImportFailures(batch.failures))"
                } else {
                    grokLastError = nil
                }
                refreshGrok(.all)
                return true
            }
            grokAccountOperationMessage = nil
            if batch.failures.contains("nothing_selected") {
                grokLastError = l10n.text(.accountsExportEmpty)
            } else if batch.failures.contains("no_credentials") || batch.failures.isEmpty {
                grokLastError = l10n.text(.grokAccountsImportNoCredentials)
            } else {
                grokLastError = "\(l10n.text(.accountsImportFailed)): \(humanizeGrokImportFailures(batch.failures))"
            }
            return false
        } catch is CancellationError {
            grokAccountOperationMessage = nil
            grokLastError = l10n.text(.grokLoginCancelled)
            return false
        } catch {
            grokAccountOperationMessage = nil
            grokLastError = grokErrorText(error)
            return false
        }
    }

    /// Export selected managed Grok accounts to a transfer pack file.
    @discardableResult
    func exportGrokAccounts(ids: [String], to url: URL) async -> Bool {
        guard let grokModule else { return false }
        do {
            let result = try await grokModule.exportAccounts(ids: ids)
            try AccountTransferCodec.write(result.pack, to: url)
            grokAccountOperationMessage = String(
                format: l10n.text(.accountsExportSucceeded),
                result.exportedCount)
            if result.failures.isEmpty {
                grokLastError = nil
            } else {
                grokLastError = "\(l10n.text(.accountsExportFailed)): \(result.failures.prefix(3).joined(separator: "; "))"
            }
            return true
        } catch {
            grokAccountOperationMessage = nil
            grokLastError = "\(l10n.text(.accountsExportFailed)): \(error.localizedDescription)"
            return false
        }
    }

    /// Returns true when at least one Grok account was imported successfully.
    @discardableResult
    func importPastedGrokCredentials(_ text: String) async -> Bool {
        guard let grokModule, !isGrokAccountOperationInProgress else { return false }
        isGrokAccountOperationInProgress = true
        grokAccountOperationMessage = l10n.text(.grokLoginWaiting)
        grokLastError = nil
        defer {
            isGrokAccountOperationInProgress = false
            grokAccountOperationWork = nil
        }
        do {
            let (batch, state) = try await grokModule.importPastedText(text)
            applyGrokAccountState(state)
            if batch.successCount > 0 {
                grokAccountState.officialIdentityChangedExternally = false
                grokPanelState.externalLoginChanged = false
                grokAccountOperationMessage = String(
                    format: l10n.text(.accountsImportSucceeded),
                    batch.successCount)
                if batch.failureCount > 0 {
                    grokLastError = "\(l10n.text(.accountsImportFailed)): \(humanizeGrokImportFailures(batch.failures))"
                } else {
                    grokLastError = nil
                }
                // Background quota refresh for newly imported accounts.
                refreshGrok(.all)
                return true
            }
            grokAccountOperationMessage = nil
            if batch.failures.contains("no_credentials") || batch.failures.isEmpty {
                grokLastError = l10n.text(.grokAccountsImportNoCredentials)
            } else {
                grokLastError = "\(l10n.text(.accountsImportFailed)): \(humanizeGrokImportFailures(batch.failures))"
            }
            return false
        } catch is CancellationError {
            grokAccountOperationMessage = nil
            grokLastError = l10n.text(.grokLoginCancelled)
            return false
        } catch {
            grokAccountOperationMessage = nil
            grokLastError = grokErrorText(error)
            return false
        }
    }

    private func humanizeGrokImportFailures(_ failures: [String]) -> String {
        failures.prefix(3).map { failure in
            if failure == "no_credentials" {
                return l10n.text(.grokAccountsImportNoCredentials)
            }
            return failure
        }.joined(separator: "; ")
    }

    func switchGrokAccount(id: String, allowWhileRunning: Bool = false) {
        cancelGrokRefresh()
        runGrokCommand(
            .makeCurrent(id: id, allowWhileRunning: allowWhileRunning),
            message: l10n.text(.grokSwitching))
    }

    func confirmGrokSwitchWhileRunning() {
        guard let id = grokRunningProcessWarningAccountID else { return }
        grokRunningProcessWarningAccountID = nil
        switchGrokAccount(id: id, allowWhileRunning: true)
    }

    func deleteGrokAccount(id: String) {
        runGrokCommand(.remove(id: id), message: nil)
    }

    func updateGrokAccountAlias(id: String, alias: String?) {
        runGrokCommand(.setAlias(id: id, alias: alias), message: nil)
    }

    func moveGrokAccount(id: String, direction: Int) {
        var ordered = grokAccountState.accounts.sorted { $0.sortIndex < $1.sortIndex }
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        runGrokCommand(.reorder(ids: ordered.map(\.id)), message: nil)
    }

    func rebuildGrokPanelState() {
        applyGrokAccountState(grokAccountState)
    }

    private func runGrokCommand(_ command: GrokAccountCommand, message: String?) {
        guard let grokModule, !isGrokAccountOperationInProgress else { return }
        let isOAuthLogin: Bool
        if case .loginOAuth = command {
            isOAuthLogin = true
        } else {
            isOAuthLogin = false
        }
        isGrokAccountOperationInProgress = true
        isGrokOAuthLoginInProgress = isOAuthLogin
        grokAccountOperationMessage = message
        grokLastError = nil
        let work = Task { [weak self] in
            guard let self else { return }
            defer {
                isGrokAccountOperationInProgress = false
                isGrokOAuthLoginInProgress = false
                grokAccountOperationWork = nil
            }
            do {
                let state = try await grokModule.apply(command)
                applyGrokAccountState(state)
                applyGrokCommandSuccess(command)
                grokLastError = nil
            } catch is CancellationError {
                grokAccountOperationMessage = nil
                grokLastError = l10n.text(.grokLoginCancelled)
            } catch GrokAccountError.loginCancelled {
                grokAccountOperationMessage = nil
                grokLastError = l10n.text(.grokLoginCancelled)
            } catch let GrokAccountError.grokProcessesRunning(processIDs) {
                _ = processIDs
                if case let .makeCurrent(id, _) = command {
                    grokRunningProcessWarningAccountID = id
                }
                grokAccountOperationMessage = nil
            } catch {
                grokAccountOperationMessage = nil
                grokLastError = grokErrorText(error)
                grokPanelState.availability = grokAvailability(for: error)
            }
        }
        grokAccountOperationWork = work
    }

    private func applyGrokAccountState(_ state: GrokAccountState) {
        grokAccountState = state
        let externalLoginChanged = grokPanelState.externalLoginChanged
            || state.officialIdentityChangedExternally
        let current = state.currentAccountID.flatMap { id in state.accounts.first { $0.id == id } }
        let quota = current?.cachedQuota.map { GrokQuotaPresentation.make(snapshot: $0, l10n: l10n) }
        let availability: GrokPanelAvailability
        if current?.requiresReauth == true {
            availability = .reauthenticationRequired
        } else if let errorCode = current?.lastError {
            availability = grokAvailability(forPersistedErrorCode: errorCode)
        } else {
            availability = grokAvailability(for: state.officialCredentialStatus, hasQuota: quota != nil)
        }
        if current?.requiresReauth == true {
            grokLastError = l10n.text(.grokReauthenticationRequired)
        } else if let errorCode = current?.lastError {
            grokLastError = GrokAccountLastErrorPresentation.text(for: errorCode, l10n: l10n)
        } else {
            grokLastError = nil
        }
        // Preserve local usage while billing identity refreshes.
        let localUsage = grokPanelState.localUsage
        let isRefreshingLocalUsage = grokPanelState.isRefreshingLocalUsage
        grokPanelState = GrokPanelViewState(
            availability: availability,
            identityName: current?.resolvedDisplayName ?? state.officialCredentialStatus.identity?.resolvedDisplayName,
            planName: GrokSubscriptionTier.displayName(from: quota?.plan) ?? quota?.plan,
            quota: quota,
            localUsage: localUsage,
            isRefreshingLocalUsage: isRefreshingLocalUsage,
            externalLoginChanged: externalLoginChanged)
        if externalLoginChanged {
            grokAccountOperationMessage = l10n.text(.grokExternalLoginChanged)
        }
    }

    private func applyGrokRefreshReport(_ report: GrokRefreshReport) {
        // Panel availability follows the account the user is looking at — never a
        // non-current sibling failure from refresh(.all).
        let relevantOutcomes: [GrokRefreshOutcome]
        switch report.target {
        case .current:
            let currentID = grokAccountState.currentAccountID
            relevantOutcomes = report.outcomes.filter { $0.accountID == currentID }
        case .account(let id):
            relevantOutcomes = report.outcomes.filter { $0.accountID == id }
        case .all:
            let currentID = grokAccountState.currentAccountID
            relevantOutcomes = report.outcomes.filter { $0.accountID == currentID }
        }

        guard !relevantOutcomes.isEmpty else { return }

        if let firstFailure = relevantOutcomes.compactMap(\.error).first {
            grokLastError = grokErrorText(firstFailure)
            grokPanelState.availability = grokAvailability(for: firstFailure)
            return
        }

        grokLastError = nil
        grokAccountOperationMessage = grokPanelState.externalLoginChanged
            ? l10n.text(.grokExternalLoginChanged)
            : nil
    }

    private func finishGrokRefresh(generation: Int) {
        guard generation == grokRefreshGeneration else { return }
        let completesFullRefresh = grokRefreshCompletesFullRefresh
        grokRefreshCompletesFullRefresh = false
        isRefreshingGrok = false
        grokRefreshingAccountIDs = []
        grokRefreshWork = nil
        if completesFullRefresh { onFullRefreshCompleted?() }
    }

    private func cancelGrokRefresh() {
        let completesFullRefresh = grokRefreshCompletesFullRefresh
        grokRefreshCompletesFullRefresh = false
        grokRefreshGeneration += 1
        grokRefreshWork?.cancel()
        grokRefreshWork = nil
        isRefreshingGrok = false
        grokRefreshingAccountIDs = []
        if completesFullRefresh { onFullRefreshCompleted?() }
    }

    private func grokRefreshIDs(_ target: GrokRefreshTarget) -> Set<String> {
        switch target {
        case .current:
            return Set(grokAccountState.currentAccountID.map { [$0] } ?? [])
        case .account(let id):
            return [id]
        case .all:
            return Set(grokAccountState.accounts.map(\.id))
        }
    }

    private func grokSuccessMessage(_ command: GrokAccountCommand) -> String? {
        switch command {
        case .loginOAuth, .importOfficial:
            return l10n.text(.grokImportSucceeded)
        case .makeCurrent:
            return l10n.text(.grokSwitchOnlyNewSessions)
        case .remove, .setAlias, .reorder:
            return nil
        }
    }

    private func applyGrokCommandSuccess(_ command: GrokAccountCommand) {
        switch command {
        case .loginOAuth, .importOfficial, .makeCurrent:
            grokAccountState.officialIdentityChangedExternally = false
            grokPanelState.externalLoginChanged = false
            // Pull billing for the newly current identity immediately so the panel
            // does not sit on stale cache or an empty state after switch/import.
            refreshGrok(.current)
        case .remove, .setAlias, .reorder:
            break
        }
        grokAccountOperationMessage = grokPanelState.externalLoginChanged
            ? l10n.text(.grokExternalLoginChanged)
            : grokSuccessMessage(command)
    }

    private func grokAvailability(
        for status: GrokOfficialCredentialStatus,
        hasQuota: Bool
    ) -> GrokPanelAvailability {
        guard grokCLIAvailable else { return .cliUnavailable }
        switch status {
        case .authenticated:
            return .ready
        case .requiresReauthentication:
            return .reauthenticationRequired
        case .missing, .apiKeyOnly, .unsupported:
            return .notLoggedIn
        case .malformed, .unreadable:
            return hasQuota ? .ready : .reauthenticationRequired
        }
    }

    private func grokAvailability(forPersistedErrorCode code: String) -> GrokPanelAvailability {
        switch code {
        case "cli_unavailable":
            return .cliUnavailable
        case "authentication_required":
            return .reauthenticationRequired
        case "billing_parse_failed":
            return .billingParseFailed
        default:
            return .failed(GrokAccountLastErrorPresentation.text(for: code, l10n: l10n))
        }
    }

    private func grokAvailability(for error: Error) -> GrokPanelAvailability {
        guard grokCLIAvailable else { return .cliUnavailable }
        guard let error = error as? GrokAccountError else {
            if error is GrokBillingDecodingError { return .billingParseFailed }
            return .failed(grokErrorText(error))
        }
        switch error {
        case .cliNotInstalled:
            return .cliUnavailable
        case .cliTooOld:
            return .cliTooOld
        case .officialCredentialMissing, .apiKeyOnlyNotManageable, .noManagedCredential:
            return .notLoggedIn
        case .officialCredentialMalformed, .invalidCredential, .credentialIdentityMismatch:
            return .reauthenticationRequired
        case .refreshFailed(_, let message) where message.lowercased().contains("parse"):
            return .billingParseFailed
        case .refreshFailed(_, let message) where message.lowercased().contains("authentication"):
            return .reauthenticationRequired
        default:
            return .failed(grokErrorText(error))
        }
    }

    private func grokErrorText(_ error: Error) -> String {
        guard let error = error as? GrokAccountError else {
            if error is GrokBillingDecodingError { return l10n.text(.grokBillingParseFailed) }
            return l10n.text(.grokRefreshFailed)
        }
        switch error {
        case .cliNotInstalled:
            return l10n.text(.grokCLIUnavailable)
        case .cliTooOld:
            return l10n.text(.grokCLITooOld)
        case .officialCredentialMissing:
            return l10n.text(.grokNotLoggedIn)
        case .officialCredentialMalformed, .invalidCredential, .credentialIdentityMismatch:
            return l10n.text(.grokReauthenticationRequired)
        case .apiKeyOnlyNotManageable, .noManagedCredential:
            return l10n.text(.grokNoManagedOAuth)
        case .accountNotFound, .credentialMissing:
            return l10n.text(.grokRefreshFailed)
        case .currentAccountCannotBeRemoved:
            return l10n.text(.grokCurrentAccountCannotDelete)
        case .grokProcessesRunning:
            return l10n.text(.grokSwitchRunningMessage)
        case .authFileLocked:
            return l10n.text(.grokSwitchFailed)
        case .loginCancelled:
            return l10n.text(.grokLoginCancelled)
        case .loginFailed:
            return l10n.text(.grokLoginFailed)
        case .refreshFailed(_, let message):
            if message.lowercased().contains("parse") {
                return l10n.text(.grokBillingParseFailed)
            }
            if message.lowercased().contains("authentication") {
                return l10n.text(.grokReauthenticationRequired)
            }
            return l10n.text(.grokRefreshFailed)
        case .unsupportedIndexVersion, .io, .partialWrite:
            return l10n.text(.grokSwitchFailed)
        }
    }

    private func grokAvailabilityText(_ availability: GrokPanelAvailability) -> String {
        switch availability {
        case .loading:
            return l10n.text(.grokRefreshing)
        case .ready:
            return l10n.text(.grokNoQuotaData)
        case .cliUnavailable:
            return l10n.text(.grokCLIUnavailable)
        case .notLoggedIn:
            return l10n.text(.grokNotLoggedIn)
        case .reauthenticationRequired:
            return l10n.text(.grokReauthenticationRequired)
        case .cliTooOld:
            return l10n.text(.grokCLITooOld)
        case .billingParseFailed:
            return l10n.text(.grokBillingParseFailed)
        case .failed(let message):
            return message
        }
    }
}
