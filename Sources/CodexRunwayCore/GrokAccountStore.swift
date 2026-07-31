import Foundation

public struct GrokAccountStore: Sendable {
    public var rootURL: URL
    public var officialHomeURL: URL

    public init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway/accounts", isDirectory: true),
        officialHomeURL: URL = GrokAccountStore.resolveOfficialHome())
    {
        self.rootURL = rootURL
        self.officialHomeURL = officialHomeURL
    }

    public static func resolveOfficialHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        guard let configured = environment["GROK_HOME"], !configured.isEmpty else {
            return homeDirectory.appendingPathComponent(".grok", isDirectory: true)
        }
        if configured == "~" { return homeDirectory }
        if configured.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(configured.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
    }

    public var indexURL: URL {
        rootURL.appendingPathComponent("grok-index.json")
    }

    public var officialAuthURL: URL {
        officialHomeURL.appendingPathComponent("auth.json")
    }

    public func accountDirectory(id: String) -> URL {
        rootURL.appendingPathComponent(sanitizePathComponent(id), isDirectory: true)
    }

    public func credentialURL(id: String) -> URL {
        accountDirectory(id: id).appendingPathComponent("auth.json")
    }

    public func pendingHomeURL(id: String) -> URL {
        rootURL.appendingPathComponent(".grok-pending-\(sanitizePathComponent(id))", isDirectory: true)
    }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try setPermissions(rootURL, mode: 0o700)
    }

    public func ensurePendingHome(id: String) throws -> URL {
        try ensureRoot()
        let url = pendingHomeURL(id: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try setPermissions(url, mode: 0o700)
        return url
    }

    public func loadIndex() throws -> GrokAccountIndex {
        try ensureRoot()
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return GrokAccountIndex()
        }
        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .grokAccountStoreDates
        let index = try decoder.decode(GrokAccountIndex.self, from: data)
        guard index.version == GrokAccountIndex.currentVersion else {
            throw GrokAccountError.unsupportedIndexVersion(index.version)
        }
        return index
    }

    public func saveIndex(_ index: GrokAccountIndex) throws {
        try ensureRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .grokAccountStoreDates
        try atomicWrite(try encoder.encode(index), to: indexURL, mode: 0o600)
    }

    public func loadCredentialData(id: String) throws -> Data {
        let url = credentialURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GrokAccountError.credentialMissing(id)
        }
        return try Data(contentsOf: url)
    }

    public func saveCredentialData(id: String, data: Data) throws {
        let document = try parseCredential(data)
        let index = try loadIndex()
        if document.stableID != id {
            guard let existing = index.account(id: id), identitiesMatch(existing.identity, document.identity) else {
                throw GrokAccountError.credentialIdentityMismatch(id)
            }
        }
        try saveCredentialDataUnchecked(id: id, data: data)
    }

    @discardableResult
    public func upsertCredentialData(
        _ data: Data,
        makeCurrent: Bool = false,
        preserveRefreshFailure: Bool = false,
        now: Date = Date()) throws -> GrokManagedAccount
    {
        let document = try parseCredential(data)
        var index = try loadIndex()
        let existing = index.accounts.first { identitiesMatch($0.identity, document.identity) }
        let id = existing?.id ?? document.stableID
        let sortIndex = existing?.sortIndex ?? ((index.accounts.map(\.sortIndex).max() ?? -1) + 1)
        var account = existing ?? GrokManagedAccount(
            id: id,
            sortIndex: sortIndex,
            identity: document.identity,
            createdAt: now)
        account.identity = document.identity
        let credentialRequiresReauthentication = document.requiresReauthentication(at: now)
        if preserveRefreshFailure {
            account.requiresReauth = account.requiresReauth || credentialRequiresReauthentication
        } else {
            account.requiresReauth = credentialRequiresReauthentication
            account.lastError = nil
        }
        if makeCurrent {
            account.lastUsedAt = now
            index.currentAccountID = id
        }

        try saveCredentialDataUnchecked(id: id, data: data)
        index.upsert(account)
        try saveIndex(index)
        return account
    }

    public func updateMetadata(_ account: GrokManagedAccount) throws {
        var index = try loadIndex()
        guard index.account(id: account.id) != nil else {
            throw GrokAccountError.accountNotFound(account.id)
        }
        index.upsert(account)
        try saveIndex(index)
    }

    public func setCurrentAccountID(_ id: String?, lastUsedAt: Date = Date()) throws {
        var index = try loadIndex()
        if let id {
            guard var account = index.account(id: id) else {
                throw GrokAccountError.accountNotFound(id)
            }
            account.lastUsedAt = lastUsedAt
            index.upsert(account)
        }
        index.currentAccountID = id
        try saveIndex(index)
    }

    public func reorder(ids: [String]) throws {
        var index = try loadIndex()
        var nextIndex = 0
        for id in ids {
            guard let position = index.accounts.firstIndex(where: { $0.id == id }) else { continue }
            index.accounts[position].sortIndex = nextIndex
            nextIndex += 1
        }
        for position in index.accounts.indices where !ids.contains(index.accounts[position].id) {
            index.accounts[position].sortIndex = nextIndex
            nextIndex += 1
        }
        try saveIndex(index)
    }

    public func loadOfficialCredentialData() throws -> Data {
        guard FileManager.default.fileExists(atPath: officialAuthURL.path) else {
            throw GrokAccountError.officialCredentialMissing
        }
        return try Data(contentsOf: officialAuthURL)
    }

    public func loadOfficialCredentialStatus(now: Date = Date()) -> GrokOfficialCredentialStatus {
        let data: Data
        do {
            data = try loadOfficialCredentialData()
        } catch GrokAccountError.officialCredentialMissing {
            return .missing
        } catch {
            return .unreadable
        }
        do {
            let document = try GrokAuthDocument.parse(data)
            if document.requiresReauthentication(at: now) {
                return .requiresReauthentication(document.identity)
            }
            return .authenticated(document.identity)
        } catch GrokAuthDocumentError.noManagedCredential {
            return containsAPIKeyScope(data) ? .apiKeyOnly : .unsupported
        } catch {
            return .malformed
        }
    }

    public func saveOfficialAuthDataAtomically(_ data: Data) throws {
        _ = try parseCredential(data)
        try FileManager.default.createDirectory(at: officialHomeURL, withIntermediateDirectories: true)
        try setPermissions(officialHomeURL, mode: 0o700)
        try atomicWrite(data, to: officialAuthURL, mode: 0o600)
    }

    func restoreOfficialAuthDataAtomically(_ data: Data?) throws {
        try FileManager.default.createDirectory(at: officialHomeURL, withIntermediateDirectories: true)
        try setPermissions(officialHomeURL, mode: 0o700)
        if let data {
            try atomicWrite(data, to: officialAuthURL, mode: 0o600)
        } else if FileManager.default.fileExists(atPath: officialAuthURL.path) {
            try FileManager.default.removeItem(at: officialAuthURL)
        }
    }

    private func saveCredentialDataUnchecked(id: String, data: Data) throws {
        try ensureRoot()
        let directory = accountDirectory(id: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setPermissions(directory, mode: 0o700)
        try atomicWrite(data, to: credentialURL(id: id), mode: 0o600)
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

    private func atomicWrite(_ data: Data, to url: URL, mode: UInt16) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .completeFileProtectionUntilFirstUserAuthentication)
        try setPermissions(temporary, mode: mode)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try setPermissions(url, mode: mode)
    }

    private func setPermissions(_ url: URL, mode: UInt16) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path)
    }

    private func sanitizePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "grok-account" : cleaned
    }

    private func identitiesMatch(_ lhs: GrokCredentialIdentity, _ rhs: GrokCredentialIdentity) -> Bool {
        if lhs.stableID == rhs.stableID { return true }
        if let lhsID = firstNonEmpty(lhs.principalID), let rhsID = firstNonEmpty(rhs.principalID) {
            return lhsID.caseInsensitiveCompare(rhsID) == .orderedSame && teamsCompatible(lhs, rhs)
        }
        if let lhsID = firstNonEmpty(lhs.userID), let rhsID = firstNonEmpty(rhs.userID) {
            return lhsID.caseInsensitiveCompare(rhsID) == .orderedSame && teamsCompatible(lhs, rhs)
        }
        if let lhsEmail = firstNonEmpty(lhs.email), let rhsEmail = firstNonEmpty(rhs.email) {
            return lhsEmail.caseInsensitiveCompare(rhsEmail) == .orderedSame && teamsCompatible(lhs, rhs)
        }
        return false
    }

    private func teamsCompatible(_ lhs: GrokCredentialIdentity, _ rhs: GrokCredentialIdentity) -> Bool {
        guard let lhsTeam = firstNonEmpty(lhs.teamID), let rhsTeam = firstNonEmpty(rhs.teamID) else {
            return true
        }
        return lhsTeam.caseInsensitiveCompare(rhsTeam) == .orderedSame
    }

    private func containsAPIKeyScope(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root[GrokAuthDocument.apiKeyScope] != nil
    }
}
