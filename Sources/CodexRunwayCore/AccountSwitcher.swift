import Foundation

public struct AccountSwitchResult: Sendable, Equatable {
    public var account: ManagedAccount
    public var auth: CodexAuth
}

/// Switches the CLI-active account by writing the selected credential to official `auth.json`.
public struct AccountSwitcher: Sendable {
    public var store: AccountStore
    public var tokenRefresher: TokenRefresher
    public var fetchQuota: @Sendable (CodexAuth) async throws -> QuotaSnapshot

    public init(
        store: AccountStore = AccountStore(),
        tokenRefresher: TokenRefresher = TokenRefresher(),
        fetchQuota: @escaping @Sendable (CodexAuth) async throws -> QuotaSnapshot = {
            try await QuotaClient().fetchQuota(auth: $0)
        })
    {
        self.store = store
        self.tokenRefresher = tokenRefresher
        self.fetchQuota = fetchQuota
    }

    public func switchTo(accountId: String, now: Date = Date()) async throws -> AccountSwitchResult {
        var auth = try store.loadCredential(id: accountId)

        // Allow full OAuth and non-expired access-token-only session credentials.
        // Block only invalid junk or expired session tokens with no refresh.
        switch auth.loginUsability {
        case .usable:
            break
        case .expiredAccessWithoutRefresh:
            throw AccountStoreError.expiredAccessWithoutRefresh
        case .invalidTokens:
            throw AccountStoreError.notUsableAsCodexLogin
        }

        // Validate the target before replacing the current login or restarting the app.
        do {
            auth = try await ensureValid(auth: auth, accountId: accountId, isActiveTarget: false)
            if !auth.isAPIKeyAuth {
                _ = try await fetchQuota(auth)
            }
        } catch {
            if (error as? URLError)?.code == .userAuthenticationRequired,
               let account = try? store.loadIndex().account(id: accountId)
            {
                try? store.updateMetadata(account.applying(error: error.localizedDescription, requiresReauth: true))
            }
            throw error
        }

        switch auth.loginUsability {
        case .usable:
            break
        case .expiredAccessWithoutRefresh:
            throw AccountStoreError.expiredAccessWithoutRefresh
        case .invalidTokens:
            throw AccountStoreError.notUsableAsCodexLogin
        }

        // Write official auth via AuthStore (strips runway-only keys, omits empty tokens).
        try store.saveOfficialAuth(auth)
        try store.saveCredential(id: accountId, auth: auth)
        try store.setActiveAccountId(accountId, lastUsedAt: now)

        let index = try store.loadIndex()
        guard var account = index.account(id: accountId) else {
            throw AccountStoreError.accountNotFound(accountId)
        }
        account = account.withIdentity(from: auth, quotaPlan: nil, now: now)
        account.cachedQuota = nil
        account.lastQuotaAt = nil
        account.lastUsedAt = now
        account.requiresReauth = false
        account.lastError = nil
        try store.updateMetadata(account)
        return AccountSwitchResult(account: account, auth: auth)
    }

    /// Refresh OAuth tokens for a managed account. Writes official auth only when it is active.
    public func ensureValidCredential(accountId: String) async throws -> CodexAuth {
        let index = try store.loadIndex()
        let isActive = index.activeAccountId == accountId
        var auth = try store.loadCredential(id: accountId)
        auth = try await ensureValid(auth: auth, accountId: accountId, isActiveTarget: isActive)
        return auth
    }

    private func ensureValid(auth: CodexAuth, accountId: String, isActiveTarget: Bool) async throws -> CodexAuth {
        if auth.isAPIKeyAuth {
            guard let key = auth.openAIAPIKey, !key.isEmpty else {
                throw AccountStoreError.invalidCredential
            }
            return auth
        }
        guard auth.canRefreshOAuth || !auth.tokens.accessToken.isEmpty else {
            throw AccountStoreError.invalidCredential
        }
        var working = auth
        if TokenInspector.isExpired(working.tokens.accessToken) {
            guard working.canRefreshOAuth else {
                // Session access tokens cannot be renewed without refresh_token.
                throw AccountStoreError.expiredAccessWithoutRefresh
            }
            try await tokenRefresher.refresh(&working, store: nil)
            try store.saveCredential(id: accountId, auth: working)
            if isActiveTarget {
                try store.saveOfficialAuth(working)
            }
        }
        return working
    }
}
