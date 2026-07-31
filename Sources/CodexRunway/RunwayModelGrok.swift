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
        switch selectedProvider {
        case .codex:
            return statusText
        case .grok:
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
    }

    var selectedQuotaMeters: [QuotaMeter] {
        selectedProvider == .codex ? quotaMeters : (grokPanelState.quota?.meters ?? [])
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
                if selectedProvider == .grok,
                   grokCLIAvailable,
                   state.currentAccountID != nil,
                   grokPanelState.quota == nil
                {
                    refreshGrok(.current)
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
        }
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
        grokPanelState = GrokPanelViewState(
            availability: availability,
            identityName: current?.resolvedDisplayName ?? state.officialCredentialStatus.identity?.resolvedDisplayName,
            planName: quota?.plan,
            quota: quota,
            externalLoginChanged: externalLoginChanged)
        if externalLoginChanged {
            grokAccountOperationMessage = l10n.text(.grokExternalLoginChanged)
        }
    }

    private func applyGrokRefreshReport(_ report: GrokRefreshReport) {
        let failures = report.outcomes.compactMap(\.error)
        guard let firstFailure = failures.first else {
            if !report.outcomes.isEmpty {
                grokLastError = nil
                grokAccountOperationMessage = grokPanelState.externalLoginChanged
                    ? l10n.text(.grokExternalLoginChanged)
                    : nil
            }
            return
        }
        grokLastError = grokErrorText(firstFailure)
        grokPanelState.availability = grokAvailability(for: firstFailure)
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
