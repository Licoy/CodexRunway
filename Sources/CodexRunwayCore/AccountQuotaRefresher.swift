import Foundation

public struct AccountQuotaRefreshResult: Sendable, Equatable {
    public var accountId: String
    public var account: ManagedAccount?
    public var errorDescription: String?
}

/// Refreshes quota for all managed OAuth accounts with bounded concurrency.
public struct AccountQuotaRefresher: Sendable {
    public var store: AccountStore
    public var switcher: AccountSwitcher
    public var quotaClient: QuotaClient
    public var maxConcurrent: Int

    public init(
        store: AccountStore = AccountStore(),
        switcher: AccountSwitcher = AccountSwitcher(),
        quotaClient: QuotaClient = QuotaClient(),
        maxConcurrent: Int = 3)
    {
        self.store = store
        self.switcher = switcher
        self.quotaClient = quotaClient
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public func refreshAll() async -> [AccountQuotaRefreshResult] {
        let index: AccountIndex
        do {
            index = try store.loadIndex()
        } catch {
            return []
        }

        // Active first for snappier sidebar/current UX.
        let ordered = index.orderedForSidebar()
        var results: [AccountQuotaRefreshResult] = []
        results.reserveCapacity(ordered.count)

        await withTaskGroup(of: AccountQuotaRefreshResult.self) { group in
            var iterator = ordered.makeIterator()
            var inFlight = 0

            func enqueueNext() {
                guard inFlight < maxConcurrent, let account = iterator.next() else { return }
                inFlight += 1
                group.addTask { [store, switcher, quotaClient] in
                    await Self.refreshOne(
                        account: account,
                        store: store,
                        switcher: switcher,
                        quotaClient: quotaClient)
                }
            }

            for _ in 0..<maxConcurrent {
                enqueueNext()
            }

            for await result in group {
                results.append(result)
                inFlight -= 1
                enqueueNext()
            }
        }

        // Preserve sidebar order in returned results.
        let order = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        return results.sorted {
            (order[$0.accountId] ?? .max) < (order[$1.accountId] ?? .max)
        }
    }

    public func refresh(accountId: String) async -> AccountQuotaRefreshResult {
        let index: AccountIndex
        do {
            index = try store.loadIndex()
        } catch {
            return AccountQuotaRefreshResult(accountId: accountId, account: nil, errorDescription: error.localizedDescription)
        }
        guard let account = index.account(id: accountId) else {
            return AccountQuotaRefreshResult(accountId: accountId, account: nil, errorDescription: "account not found")
        }
        return await Self.refreshOne(
            account: account,
            store: store,
            switcher: switcher,
            quotaClient: quotaClient)
    }

    private static func refreshOne(
        account: ManagedAccount,
        store: AccountStore,
        switcher: AccountSwitcher,
        quotaClient: QuotaClient) async -> AccountQuotaRefreshResult
    {
        if account.authMode == .apiKey {
            // ChatGPT quota endpoints do not apply to pure API-key accounts.
            var updated = account
            updated.lastError = nil
            updated.requiresReauth = false
            try? store.updateMetadata(updated)
            return AccountQuotaRefreshResult(accountId: account.id, account: updated, errorDescription: nil)
        }

        do {
            let auth = try await switcher.ensureValidCredential(accountId: account.id)
            let quota = try await quotaClient.fetchQuota(auth: auth)
            var updated = account.withIdentity(from: auth, quotaPlan: quota.plan).applying(quota: quota)
            if shouldFetchWorkspaceName(for: updated),
               let workspaceName = await quotaClient.fetchWorkspaceName(auth: auth)
            {
                updated.workspaceName = workspaceName
            }
            try store.updateMetadata(updated)
            // Keep credential identity fields in sync after refresh.
            try? store.saveCredential(id: account.id, auth: auth)
            return AccountQuotaRefreshResult(accountId: account.id, account: updated, errorDescription: nil)
        } catch {
            let message = error.localizedDescription
            let needsReauth = (error as? URLError)?.code == .userAuthenticationRequired
            let updated = account.applying(error: message, requiresReauth: needsReauth)
            try? store.updateMetadata(updated)
            return AccountQuotaRefreshResult(accountId: account.id, account: updated, errorDescription: message)
        }
    }

    private static func shouldFetchWorkspaceName(for account: ManagedAccount) -> Bool {
        guard account.workspaceName == nil else { return false }
        switch account.subscriptionTier {
        case .team, .business, .enterprise, .edu:
            return true
        default:
            return false
        }
    }
}
