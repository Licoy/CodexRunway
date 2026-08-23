import Foundation

public enum AccountStoreError: Error, Sendable, Equatable {
    case accountNotFound(String)
    case credentialMissing(String)
    case invalidCredential
    case missingRefreshToken
    case expiredAccessWithoutRefresh
    case notUsableAsCodexLogin
    case io(String)
}

/// Multi-account index + per-account credential files under `~/.codex-runway/accounts`.
public struct AccountStore: Sendable {
    public var rootURL: URL
    public var officialAuthURL: URL

    public init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway/accounts"),
        officialAuthURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json"))
    {
        self.rootURL = rootURL
        self.officialAuthURL = officialAuthURL
    }

    public var indexURL: URL {
        rootURL.appendingPathComponent("index.json")
    }

    public func accountDirectory(id: String) -> URL {
        rootURL.appendingPathComponent(sanitizePathComponent(id), isDirectory: true)
    }

    public func credentialURL(id: String) -> URL {
        accountDirectory(id: id).appendingPathComponent("auth.json")
    }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try setPOSIXPermissions(rootURL, mode: 0o700)
    }

    public func loadIndex() throws -> AccountIndex {
        try ensureRoot()
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return AccountIndex()
        }
        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .accountStoreDates
        var index = try decoder.decode(AccountIndex.self, from: data)
        // Legacy rows may not persist identity display metadata. Hydrate it from the row's existing
        // credential without renaming ids/directories or changing active/sort metadata.
        for position in index.accounts.indices where index.accounts[position].authMode == .oauth {
            let needsIdentityMetadata = index.accounts[position].userId == nil
                || index.accounts[position].subjectId == nil
                || index.accounts[position].accountId == nil
                || index.accounts[position].email == nil
                || index.accounts[position].workspaceName == nil
            guard needsIdentityMetadata,
                  let auth = try? loadCredential(id: index.accounts[position].id)
            else { continue }
            if index.accounts[position].userId == nil {
                index.accounts[position].userId = AccountIdentity.oauthUserId(for: auth)
            }
            if index.accounts[position].subjectId == nil {
                index.accounts[position].subjectId = AccountIdentity.oauthSubjectId(for: auth)
            }
            if let workspaceId = AccountIdentity.routingWorkspaceId(for: auth) {
                index.accounts[position].accountId = workspaceId
            }
            if index.accounts[position].email == nil {
                index.accounts[position].email = AccountIdentity.oauthEmail(for: auth)
            }
            if index.accounts[position].workspaceName == nil {
                index.accounts[position].workspaceName = AccountIdentity.oauthWorkspaceName(for: auth)
            }
        }
        return index
    }

    public func saveIndex(_ index: AccountIndex) throws {
        try ensureRoot()
        try atomicWriteJSON(index, to: indexURL, mode: 0o600)
    }

    public func loadCredential(id: String) throws -> CodexAuth {
        let data = try loadCredentialData(id: id)
        do {
            return try JSONDecoder().decode(CodexAuth.self, from: data)
        } catch {
            throw AccountStoreError.invalidCredential
        }
    }

    public func loadCredentialData(id: String) throws -> Data {
        let url = credentialURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AccountStoreError.credentialMissing(id)
        }
        return try Data(contentsOf: url)
    }

    public func saveCredential(id: String, auth: CodexAuth) throws {
        try ensureRoot()
        let directory = accountDirectory(id: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setPOSIXPermissions(directory, mode: 0o700)
        // Managed library may keep session/partial credentials; official writes stay strict.
        let store = CodexAuthStore(authURL: credentialURL(id: id))
        try store.save(auth, allowUnusable: true)
        try setPOSIXPermissions(credentialURL(id: id), mode: 0o600)
    }

    /// Copy the managed credential file into official `~/.codex/auth.json` without re-encoding.
    public func installCredentialAsOfficial(id: String) throws -> CodexAuth {
        let data = try loadCredentialData(id: id)
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        switch auth.loginUsability {
        case .usable:
            break
        case .expiredAccessWithoutRefresh:
            throw AccountStoreError.expiredAccessWithoutRefresh
        case .invalidTokens:
            throw AccountStoreError.notUsableAsCodexLogin
        }
        try saveOfficialAuthRaw(data)
        return auth
    }

    public func saveOfficialAuthRaw(_ data: Data) throws {
        let store = CodexAuthStore(authURL: officialAuthURL)
        // Re-save through AuthStore so runway-only keys are stripped and empties cleaned.
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        try store.save(auth)
    }

    public func deleteAccount(id: String) throws {
        var index = try loadIndex()
        index.remove(id: id)
        try saveIndex(index)
        let directory = accountDirectory(id: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Upsert by stable identity (account id / email / token fingerprint). Returns final account id.
    @discardableResult
    public func upsert(
        auth: CodexAuth,
        makeActive: Bool = false,
        alias: String? = nil,
        note: String? = nil,
        now: Date = Date()) throws -> ManagedAccount
    {
        var index = try loadIndex()
        let existing = index.accounts.first { AccountIdentity.matches(account: $0, auth: auth) }
        let sortIndex = existing?.sortIndex ?? (index.accounts.map(\.sortIndex).max() ?? -1) + 1
        // Always rebuild identity (email / displayName / plan) from the new credential.
        var account = ManagedAccount.make(
            id: existing?.id,
            auth: auth,
            sortIndex: sortIndex,
            alias: alias ?? existing?.alias,
            note: note ?? existing?.note,
            quotaPlan: nil,
            now: existing?.createdAt ?? now)
        if let existing {
            account.createdAt = existing.createdAt
            account.lastUsedAt = existing.lastUsedAt
            account.sortIndex = existing.sortIndex
            account.workspaceName = firstNonEmpty(account.workspaceName, existing.workspaceName)
            // Drop stale meters / errors so the row refreshes immediately after re-import.
            account.cachedQuota = nil
            account.lastQuotaAt = nil
            account.requiresReauth = false
            account.lastError = nil
        }
        try saveCredential(id: account.id, auth: auth)
        index.upsert(account)
        if makeActive || index.activeAccountId == nil {
            index.activeAccountId = account.id
            account.lastUsedAt = now
            index.upsert(account)
        }
        try saveIndex(index)
        return index.account(id: account.id) ?? account
    }

    public func updateMetadata(_ account: ManagedAccount) throws {
        var index = try loadIndex()
        guard index.account(id: account.id) != nil else {
            throw AccountStoreError.accountNotFound(account.id)
        }
        index.upsert(account)
        try saveIndex(index)
    }

    public func setActiveAccountId(_ id: String?, lastUsedAt: Date = Date()) throws {
        var index = try loadIndex()
        if let id {
            guard var account = index.account(id: id) else {
                throw AccountStoreError.accountNotFound(id)
            }
            account.lastUsedAt = lastUsedAt
            index.upsert(account)
            index.activeAccountId = id
        } else {
            index.activeAccountId = nil
        }
        try saveIndex(index)
    }

    public func reorder(ids: [String]) throws {
        var index = try loadIndex()
        index.reindexSortOrder(ids)
        try saveIndex(index)
    }

    public func loadOfficialAuth() throws -> CodexAuth {
        let data = try Data(contentsOf: officialAuthURL)
        return try JSONDecoder().decode(CodexAuth.self, from: data)
    }

    public func saveOfficialAuth(_ auth: CodexAuth) throws {
        let store = CodexAuthStore(authURL: officialAuthURL)
        try store.save(auth)
    }

    /// Import official `auth.json` into the store (upsert) and mark active when requested.
    @discardableResult
    public func importOfficialAuth(makeActive: Bool = true, now: Date = Date()) throws -> ManagedAccount {
        let auth = try loadOfficialAuth()
        return try upsert(auth: auth, makeActive: makeActive, now: now)
    }

    /// If the official auth file identity diverges from `activeAccountId`, import/update and mark it active.
    @discardableResult
    public func syncFromOfficialAuth(now: Date = Date()) throws -> AccountIndex {
        var index = try loadIndex()
        let official: CodexAuth
        do {
            official = try loadOfficialAuth()
        } catch {
            // Official auth missing/corrupt — try restore from a usable managed account.
            _ = try? repairOfficialAuthFromManagedAccounts(now: now)
            return try loadIndex()
        }

        // Official auth present but unusable (truncated tokens / empty refresh) — restore before Codex thrashing.
        if official.loginUsability != .usable {
            if let repaired = try? repairOfficialAuthFromManagedAccounts(now: now) {
                return repaired
            }
            // Still mark active managed entry as needing reauth when its credential is also bad.
            if let activeId = index.activeAccountId, var active = index.account(id: activeId) {
                active.requiresReauth = true
                active.lastError = "invalid credential"
                index.upsert(active)
                try? saveIndex(index)
            }
            return index
        }

        if index.accounts.isEmpty {
            _ = try upsert(auth: official, makeActive: true, now: now)
            return try loadIndex()
        }

        if let existing = index.accounts.first(where: { AccountIdentity.matches(account: $0, auth: official) }) {
            // Official is usable (gated above). Still avoid clobbering a managed credential that
            // already has a refresh_token when official is access-token-only (session), etc.
            let existingCred = try? loadCredential(id: existing.id)
            let shouldReplaceManaged = shouldReplaceManagedCredential(existing: existingCred, with: official)
            if shouldReplaceManaged {
                try saveCredential(id: existing.id, auth: official)
            }
            var updated = existing.withIdentity(
                from: shouldReplaceManaged ? official : (existingCred ?? official),
                quotaPlan: existing.planType,
                now: now)
            updated.lastUsedAt = now
            updated.requiresReauth = false
            updated.lastError = nil
            index.upsert(updated)
            index.activeAccountId = existing.id
            try saveIndex(index)
            return index
        }

        _ = try upsert(auth: official, makeActive: true, now: now)
        return try loadIndex()
    }

    /// When `~/.codex/auth.json` is missing or broken, reinstall the best managed OAuth credential.
    @discardableResult
    public func repairOfficialAuthFromManagedAccounts(now: Date = Date()) throws -> AccountIndex {
        var index = try loadIndex()
        let orderedIds: [String] = {
            var ids: [String] = []
            if let active = index.activeAccountId { ids.append(active) }
            ids.append(contentsOf: index.accounts.map(\.id).filter { !ids.contains($0) })
            return ids
        }()

        for id in orderedIds {
            guard let auth = try? loadCredential(id: id) else { continue }
            guard auth.loginUsability == .usable else {
                if var account = index.account(id: id) {
                    account.requiresReauth = true
                    index.upsert(account)
                }
                continue
            }
            try saveOfficialAuth(auth)
            index.activeAccountId = id
            var account = index.account(id: id) ?? ManagedAccount.make(id: id, auth: auth, now: now)
            account = account.withIdentity(from: auth, quotaPlan: account.planType, now: now)
            account.requiresReauth = false
            account.lastError = nil
            account.lastUsedAt = now
            index.upsert(account)
            try saveIndex(index)
            return index
        }
        try saveIndex(index)
        return index
    }

    /// Prefer keeping a managed credential that can refresh over a weaker official snapshot.
    private func shouldReplaceManagedCredential(existing: CodexAuth?, with incoming: CodexAuth) -> Bool {
        guard let existing else { return true }
        if existing == incoming { return false }
        // Never replace a full OAuth credential (has refresh) with access-token-only session.
        if existing.canRefreshOAuth, !incoming.canRefreshOAuth {
            return false
        }
        // Never replace usable with unusable.
        if existing.loginUsability == .usable, incoming.loginUsability != .usable {
            return false
        }
        return true
    }

    private func atomicWriteJSON<T: Encodable>(_ value: T, to url: URL, mode: UInt16) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .accountStoreDates
        let data = try encoder.encode(value)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .completeFileProtectionUntilFirstUserAuthentication)
        try setPOSIXPermissions(temporary, mode: mode)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        try setPOSIXPermissions(url, mode: mode)
    }

    private func setPOSIXPermissions(_ url: URL, mode: UInt16) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path)
    }

    private func sanitizePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") }
        let cleaned = String(scalars)
        return cleaned.isEmpty ? "account" : cleaned
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    /// Fractional-second ISO-8601 for stable round-trips of account index dates.
    static var accountStoreDates: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(AccountStoreDateFormat.string(from: date))
        }
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static var accountStoreDates: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = AccountStoreDateFormat.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date: \(raw)")
        }
    }
}

private enum AccountStoreDateFormat {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
