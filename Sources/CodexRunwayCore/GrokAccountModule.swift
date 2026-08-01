import Darwin
import Foundation

private enum GrokBillingAttempt {
    case success(GrokQuotaSnapshot)
    case failure(Error)
}

public actor GrokAccountModule {
    public typealias RunningProcessIDs = @Sendable () async throws -> [Int32]

    private let store: GrokAccountStore
    private let cli: GrokCLIClient
    private let runningProcessIDs: RunningProcessIDs
    private let now: @Sendable () -> Date
    private var operationLocked = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingOfficialIdentityChange = false

    public init() {
        self.store = GrokAccountStore()
        self.cli = GrokCLIClient()
        self.runningProcessIDs = { try await GrokProcessInspector.runningProcessIDs() }
        self.now = Date.init
    }

    init(
        store: GrokAccountStore,
        cli: GrokCLIClient,
        runningProcessIDs: @escaping RunningProcessIDs,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.store = store
        self.cli = cli
        self.runningProcessIDs = runningProcessIDs
        self.now = now
    }

    public func load() async throws -> GrokAccountState {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        return try reconcileOfficialIdentity(consumingExternalChange: true)
    }

    public func refresh(_ target: GrokRefreshTarget) async -> GrokRefreshReport {
        await acquireOperation()
        defer { releaseOperation() }
        let startedAt = now()
        guard !Task.isCancelled else {
            return GrokRefreshReport(target: target, outcomes: [], startedAt: startedAt, finishedAt: now())
        }

        let outcomes: [GrokRefreshOutcome]
        do {
            let state = try reconcileOfficialIdentity(consumingExternalChange: false)
            let ids = refreshAccountIDs(target: target, state: state)
            var collected: [GrokRefreshOutcome] = []
            for id in ids {
                guard !Task.isCancelled else { break }
                collected.append(await refreshAccount(id: id))
            }
            outcomes = collected
        } catch {
            outcomes = [GrokRefreshOutcome(
                accountID: refreshFailureAccountID(target),
                error: accountError(error, accountID: refreshFailureAccountID(target)))]
        }
        return GrokRefreshReport(
            target: target,
            outcomes: outcomes,
            startedAt: startedAt,
            finishedAt: now())
    }

    public func apply(_ command: GrokAccountCommand) async throws -> GrokAccountState {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let acknowledgesExternalIdentityChange: Bool
        switch command {
        case .loginOAuth:
            try await loginOAuth()
            acknowledgesExternalIdentityChange = true
        case .importOfficial:
            try importOfficial()
            acknowledgesExternalIdentityChange = true
        case let .makeCurrent(id, allowWhileRunning):
            try await makeCurrent(id: id, allowWhileRunning: allowWhileRunning)
            acknowledgesExternalIdentityChange = true
        case let .remove(id):
            try store.remove(id: id)
            acknowledgesExternalIdentityChange = false
        case let .setAlias(id, alias):
            try setAlias(id: id, alias: alias)
            acknowledgesExternalIdentityChange = false
        case let .reorder(ids):
            try store.reorder(ids: ids)
            acknowledgesExternalIdentityChange = false
        }
        var state = try reconcileOfficialIdentity(consumingExternalChange: false)
        if acknowledgesExternalIdentityChange {
            pendingOfficialIdentityChange = false
            state.officialIdentityChangedExternally = false
        }
        return state
    }

    /// Import pasted Grok auth.json / credential JSON. Partial success is reported in the batch result.
    public func importPastedText(_ text: String) async throws -> (GrokAccountImportBatchResult, GrokAccountState) {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let payloads = GrokAccountImporter().parsePayloads(from: text)
        if payloads.isEmpty {
            let state = try reconcileOfficialIdentity(consumingExternalChange: false)
            return (GrokAccountImportBatchResult(succeeded: [], failures: ["no_credentials"]), state)
        }

        let before = try store.loadIndex()
        let officialStatus = store.loadOfficialCredentialStatus(now: now())
        let canBootstrapCurrent = before.accounts.isEmpty && !officialStatus.hasManagedLogin
        var succeeded: [GrokManagedAccount] = []
        var failures: [String] = []
        var isFirst = true

        for (index, data) in payloads.enumerated() {
            try Task.checkCancellation()
            let label = payloads.count == 1 ? "json" : "json[\(index)]"
            do {
                let document = try parseCredential(data)
                let makeCurrent = isFirst && canBootstrapCurrent
                let account = try store.upsertCredentialData(data, makeCurrent: makeCurrent, now: now())
                // Keep official auth in sync when bootstrapping, re-importing the current
                // account, or pasting credentials for the identity already on disk officially.
                if shouldInstallPastedAccount(
                    accountID: account.id,
                    document: document,
                    before: before,
                    officialStatus: officialStatus,
                    bootstrapping: makeCurrent)
                {
                    try installCurrentAccount(id: account.id)
                }
                succeeded.append(account)
                isFirst = false
            } catch {
                failures.append("\(label): \(safeImportFailureMessage(error))")
            }
        }

        var state = try reconcileOfficialIdentity(consumingExternalChange: false)
        if !succeeded.isEmpty {
            pendingOfficialIdentityChange = false
            state.officialIdentityChangedExternally = false
        }
        return (GrokAccountImportBatchResult(succeeded: succeeded, failures: failures), state)
    }

    private func safeImportFailureMessage(_ error: Error) -> String {
        if let error = error as? GrokAccountError {
            switch error {
            case .noManagedCredential, .apiKeyOnlyNotManageable:
                return "no manageable Grok OAuth credential"
            case .invalidCredential, .officialCredentialMalformed:
                return "invalid Grok credential"
            case .credentialIdentityMismatch:
                return "credential identity mismatch"
            default:
                return "import failed"
            }
        }
        return "import failed"
    }

    private func shouldInstallPastedAccount(
        accountID: String,
        document: GrokAuthDocument,
        before: GrokAccountIndex,
        officialStatus: GrokOfficialCredentialStatus,
        bootstrapping: Bool) -> Bool
    {
        if bootstrapping { return true }
        if before.currentAccountID == accountID { return true }
        if let official = officialStatus.identity,
           official.stableID == accountID || official.stableID == document.stableID
        {
            return true
        }
        return false
    }

    private func reconcileOfficialIdentity(consumingExternalChange: Bool) throws -> GrokAccountState {
        let previous = try store.loadIndex()
        let status = store.loadOfficialCredentialStatus(now: now())
        let currentID: String?

        switch status {
        case .authenticated, .requiresReauthentication:
            let data = try store.loadOfficialCredentialData()
            let account = try store.upsertCredentialData(
                data,
                makeCurrent: true,
                preserveRefreshFailure: true,
                now: now())
            currentID = account.id
        case .missing, .malformed, .unreadable, .apiKeyOnly, .unsupported:
            try store.setCurrentAccountID(nil, lastUsedAt: now())
            currentID = nil
        }

        let index = try store.loadIndex()
        let changedExternally = previous.currentAccountID != nil
            && previous.currentAccountID != currentID
        if changedExternally {
            pendingOfficialIdentityChange = true
        }
        let shouldReportExternalChange = changedExternally
            || (consumingExternalChange && pendingOfficialIdentityChange)
        if consumingExternalChange {
            pendingOfficialIdentityChange = false
        }
        return GrokAccountState(
            officialCredentialStatus: status,
            currentAccountID: currentID,
            accounts: index.orderedAccounts(),
            officialIdentityChangedExternally: shouldReportExternalChange)
    }

    private func refreshAccountIDs(target: GrokRefreshTarget, state: GrokAccountState) -> [String] {
        switch target {
        case .current:
            return state.currentAccountID.map { [$0] } ?? []
        case .account(let id):
            return [id]
        case .all:
            var ids = state.accounts.map(\.id)
            if let current = state.currentAccountID,
               let position = ids.firstIndex(of: current)
            {
                ids.remove(at: position)
                ids.insert(current, at: 0)
            }
            return ids
        }
    }

    private func refreshAccount(id: String) async -> GrokRefreshOutcome {
        let account: GrokManagedAccount
        let currentID: String?
        do {
            let index = try store.loadIndex()
            guard let found = index.account(id: id) else {
                throw GrokAccountError.accountNotFound(id)
            }
            account = found
            currentID = index.currentAccountID
        } catch {
            return GrokRefreshOutcome(accountID: id, error: accountError(error, accountID: id))
        }

        let isCurrent = id == currentID
        let homeURL = isCurrent ? store.officialHomeURL : store.accountDirectory(id: id)
        let originalCredential: Data?
        do {
            originalCredential = isCurrent ? nil : try store.loadCredentialData(id: id)
        } catch {
            return refreshFailureOutcome(error, account: account)
        }

        let attempt: GrokBillingAttempt
        do {
            attempt = .success(try await cli.billing(homeURL: homeURL))
        } catch {
            attempt = .failure(error)
        }

        var credentialFinalizationError: Error?
        if let originalCredential {
            do {
                credentialFinalizationError = try finalizeManagedCredential(
                    id: id,
                    restoring: originalCredential)
            } catch {
                return refreshFailureOutcome(error, account: account)
            }
        } else {
            do {
                try mirrorOfficialCredential(to: id)
            } catch {
                credentialFinalizationError = error
            }
        }

        switch attempt {
        case let .failure(error):
            return refreshFailureOutcome(error, account: account)
        case let .success(snapshot):
            if let credentialFinalizationError {
                return refreshFailureOutcome(credentialFinalizationError, account: account)
            }
            do {
                try Task.checkCancellation()
                var updated = try requireAccount(id)
                updated = updated.applying(snapshot: snapshot)
                try store.updateMetadata(updated)
                return GrokRefreshOutcome(accountID: id, snapshot: snapshot)
            } catch {
                return refreshFailureOutcome(error, account: account)
            }
        }
    }

    private func finalizeManagedCredential(id: String, restoring originalData: Data) throws -> Error? {
        let validationError: Error
        do {
            try validateManagedCredential(id: id)
            return nil
        } catch {
            validationError = error
        }

        do {
            try store.saveCredentialData(id: id, data: originalData)
            guard try store.loadCredentialData(id: id) == originalData else {
                throw GrokAccountError.io("Managed Grok credential rollback verification failed.")
            }
        } catch {
            throw GrokAccountError.partialWrite(
                "Managed Grok credential rollback could not be verified.")
        }
        return validationError
    }

    private func refreshFailureOutcome(
        _ error: Error,
        account: GrokManagedAccount
    ) -> GrokRefreshOutcome {
        let failure = accountError(error, accountID: account.id)
        if case .partialWrite = failure {
            return GrokRefreshOutcome(
                accountID: account.id,
                error: failure,
                retainedStaleSnapshot: account.cachedQuota != nil)
        }
        do {
            var updated = try requireAccount(account.id)
            updated = updated.applying(
                error: persistedRefreshErrorCode(error),
                requiresReauth: isAuthenticationFailure(error))
            try store.updateMetadata(updated)
        } catch {
            return GrokRefreshOutcome(
                accountID: account.id,
                error: accountError(error, accountID: account.id),
                retainedStaleSnapshot: account.cachedQuota != nil)
        }
        return GrokRefreshOutcome(
            accountID: account.id,
            error: failure,
            retainedStaleSnapshot: account.cachedQuota != nil)
    }

    private func mirrorOfficialCredential(to accountID: String) throws {
        let data = try store.loadOfficialCredentialData()
        let document = try parseCredential(data)
        let matchesStoredAccount = try identitiesMatchStoredAccount(
            document.identity,
            accountID: accountID)
        guard document.stableID == accountID || matchesStoredAccount else {
            _ = try reconcileOfficialIdentity(consumingExternalChange: false)
            throw GrokAccountError.credentialIdentityMismatch(accountID)
        }
        try store.saveCredentialData(id: accountID, data: data)
    }

    private func validateManagedCredential(id: String) throws {
        let data = try store.loadCredentialData(id: id)
        let document = try parseCredential(data)
        let matchesStoredAccount = try identitiesMatchStoredAccount(document.identity, accountID: id)
        guard document.stableID == id || matchesStoredAccount else {
            throw GrokAccountError.credentialIdentityMismatch(id)
        }
        try store.saveCredentialData(id: id, data: data)
    }

    private func identitiesMatchStoredAccount(
        _ identity: GrokCredentialIdentity,
        accountID: String
    ) throws -> Bool {
        let account = try requireAccount(accountID)
        if account.identity.stableID == identity.stableID { return true }
        if let lhs = account.identity.principalID, let rhs = identity.principalID {
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
                && teamsMatch(account.identity.teamID, identity.teamID)
        }
        if let lhs = account.identity.userID, let rhs = identity.userID {
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
                && teamsMatch(account.identity.teamID, identity.teamID)
        }
        return false
    }

    private func loginOAuth() async throws {
        let pendingID = UUID().uuidString
        let pendingHome = try store.ensurePendingHome(id: pendingID)
        do {
            try await cli.loginOAuth(homeURL: pendingHome)
            try Task.checkCancellation()
            let data = try Data(contentsOf: pendingHome.appendingPathComponent("auth.json"))
            _ = try parseCredential(data)
            let before = try store.loadIndex()
            let officialStatus = store.loadOfficialCredentialStatus(now: now())
            let account = try store.upsertCredentialData(data, makeCurrent: false, now: now())
            if before.accounts.isEmpty && !officialStatus.hasManagedLogin {
                try installCurrentAccount(id: account.id)
            }
            try removePendingHome(pendingHome)
        } catch is CancellationError {
            try removePendingHome(pendingHome)
            throw GrokAccountError.loginCancelled
        } catch let error as GrokAccountError {
            try removePendingHome(pendingHome)
            throw error
        } catch {
            try removePendingHome(pendingHome)
            throw GrokAccountError.loginFailed(safeLoginMessage(error))
        }
    }

    private func importOfficial() throws {
        let status = store.loadOfficialCredentialStatus(now: now())
        switch status {
        case .authenticated, .requiresReauthentication:
            let data = try store.loadOfficialCredentialData()
            _ = try store.upsertCredentialData(data, makeCurrent: true, now: now())
        case .missing:
            throw GrokAccountError.officialCredentialMissing
        case .apiKeyOnly:
            throw GrokAccountError.apiKeyOnlyNotManageable
        case .malformed, .unreadable, .unsupported:
            throw GrokAccountError.officialCredentialMalformed
        }
    }

    private func makeCurrent(id: String, allowWhileRunning: Bool) async throws {
        _ = try requireAccount(id)
        if !allowWhileRunning {
            let processIDs: [Int32]
            do {
                processIDs = try await runningProcessIDs()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw GrokAccountError.io("Unable to inspect running Grok processes.")
            }
            try Task.checkCancellation()
            if !processIDs.isEmpty {
                throw GrokAccountError.grokProcessesRunning(processIDs)
            }
        }
        try Task.checkCancellation()
        try installCurrentAccount(id: id)
    }

    private func installCurrentAccount(id: String) throws {
        let targetData = try store.loadCredentialData(id: id)
        let target = try parseCredential(targetData)
        let targetAccount = try requireAccount(id)
        guard target.stableID == id
            || targetAccount.identity.stableID == target.identity.stableID
        else {
            throw GrokAccountError.credentialIdentityMismatch(id)
        }

        try GrokAuthFileLock.withLock(authURL: store.officialAuthURL) {
            let originalIndex = try store.loadIndex()
            let officialData: Data?
            do {
                officialData = try store.loadOfficialCredentialData()
            } catch GrokAccountError.officialCredentialMissing {
                officialData = nil
            }

            if let officialData {
                do {
                    _ = try store.upsertCredentialData(officialData, makeCurrent: false, now: now())
                } catch GrokAccountError.noManagedCredential {
                    // API-key-only official data is preserved by the scope merge below.
                }
            }

            let merged = try GrokAuthDocument.replacingManagedScopes(
                in: officialData,
                with: targetData)
            do {
                try store.saveOfficialAuthDataAtomically(merged)
                let installed = try parseCredential(store.loadOfficialCredentialData())
                guard installed.stableID == target.stableID else {
                    throw GrokAccountError.io("Official Grok credential verification failed.")
                }
                try store.setCurrentAccountID(id, lastUsedAt: now())
            } catch {
                do {
                    try rollbackSwitch(officialData: officialData, index: originalIndex)
                } catch {
                    throw GrokAccountError.partialWrite(
                        "Official Grok credential rollback could not be verified.")
                }
                if let accountError = error as? GrokAccountError {
                    throw accountError
                }
                throw GrokAccountError.io("Unable to switch the official Grok credential.")
            }
        }
    }

    private func rollbackSwitch(officialData: Data?, index: GrokAccountIndex) throws {
        try store.restoreOfficialAuthDataAtomically(officialData)
        if try store.loadIndex() != index {
            try store.saveIndex(index)
        }

        if let officialData {
            guard try store.loadOfficialCredentialData() == officialData else {
                throw GrokAccountError.io("Official Grok credential rollback verification failed.")
            }
        } else if FileManager.default.fileExists(atPath: store.officialAuthURL.path) {
            throw GrokAccountError.io("Official Grok credential removal could not be verified.")
        }
        guard try store.loadIndex() == index else {
            throw GrokAccountError.io("Grok account index rollback verification failed.")
        }
    }

    private func setAlias(id: String, alias: String?) throws {
        var account = try requireAccount(id)
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        account.alias = trimmed?.isEmpty == false ? trimmed : nil
        try store.updateMetadata(account)
    }

    private func requireAccount(_ id: String) throws -> GrokManagedAccount {
        guard let account = try store.loadIndex().account(id: id) else {
            throw GrokAccountError.accountNotFound(id)
        }
        return account
    }

    private func parseCredential(_ data: Data) throws -> GrokAuthDocument {
        do {
            return try GrokAuthDocument.parse(data)
        } catch GrokAuthDocumentError.noManagedCredential {
            throw GrokAccountError.noManagedCredential
        } catch {
            throw GrokAccountError.invalidCredential
        }
    }

    private func removePendingHome(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw GrokAccountError.io("Unable to clean up the pending Grok login directory.")
        }
    }

    private func accountError(_ error: Error, accountID: String) -> GrokAccountError {
        if let error = error as? GrokAccountError { return error }
        if let error = error as? GrokCLIError {
            if case let .requestFailed(message) = error,
               message.lowercased().contains("method not found")
            {
                return .cliTooOld("unknown")
            }
            return .refreshFailed(accountID: accountID, message: persistedRefreshErrorCode(error))
        }
        return .refreshFailed(accountID: accountID, message: persistedRefreshErrorCode(error))
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        if let error = error as? GrokCLIError, error == .authenticationRequired { return true }
        return false
    }

    private func persistedRefreshErrorCode(_ error: Error) -> String {
        switch error {
        case GrokCLIError.binaryNotFound:
            return "cli_unavailable"
        case GrokCLIError.authenticationRequired:
            return "authentication_required"
        case GrokCLIError.timeout:
            return "timeout"
        case GrokCLIError.malformedResponse:
            return "billing_parse_failed"
        case is GrokBillingDecodingError, is DecodingError:
            return "billing_parse_failed"
        case is CancellationError:
            return "cancelled"
        default:
            return "refresh_failed"
        }
    }

    private func safeLoginMessage(_ error: Error) -> String {
        if let error = error as? GrokOAuthLogin.Error {
            switch error {
            case .expired:
                return "Grok device code expired. Try signing in again."
            case .denied:
                return "Grok device authorization was denied."
            case .browserOpenFailed:
                return "Could not open the browser for Grok sign-in."
            case .missingIdentity:
                return "Grok sign-in completed but no user identity was returned."
            case .discoveryFailed, .invalidEndpoint, .deviceCodeFailed, .tokenFailed, .writeFailed:
                return "Grok OAuth login failed."
            case .authorizationPending, .slowDown:
                return "Grok OAuth login failed."
            }
        }
        switch error {
        case GrokCLIError.binaryNotFound:
            return "Grok CLI is not installed."
        case GrokCLIError.timeout:
            return "Grok OAuth login timed out."
        default:
            return "Grok OAuth login failed."
        }
    }

    private func refreshFailureAccountID(_ target: GrokRefreshTarget) -> String {
        switch target {
        case .current:
            return "current"
        case .account(let id):
            return id
        case .all:
            return "all"
        }
    }

    private func teamsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        }
    }

    private func acquireOperation() async {
        if !operationLocked {
            operationLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationLocked = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}

private extension GrokOfficialCredentialStatus {
    var hasManagedLogin: Bool {
        switch self {
        case .authenticated, .requiresReauthentication:
            return true
        case .missing, .malformed, .unreadable, .apiKeyOnly, .unsupported:
            return false
        }
    }
}

private enum GrokProcessInspector {
    static func runningProcessIDs() async throws -> [Int32] {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,comm=,args="]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8)
            else {
                throw GrokAccountError.io("Unable to inspect running Grok processes.")
            }
            return text.split(whereSeparator: \.isNewline).compactMap(processIDIfGrok)
        }.value
    }

    private static func processIDIfGrok(_ line: Substring) -> Int32? {
        let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
        guard fields.count >= 2,
              let processID = Int32(fields[0]),
              processID != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let command = URL(fileURLWithPath: String(fields[1])).lastPathComponent.lowercased()
        guard command == "grok" else { return nil }
        return processID
    }
}

private enum GrokAuthFileLock {
    static func withLock<T>(authURL: URL, operation: () throws -> T) throws -> T {
        let directory = authURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o700))],
            ofItemAtPath: directory.path)
        let lockURL = URL(fileURLWithPath: authURL.path + ".lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw GrokAccountError.io("Unable to open the Grok credential lock.")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw GrokAccountError.authFileLocked
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
