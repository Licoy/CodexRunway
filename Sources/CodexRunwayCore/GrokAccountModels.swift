import Foundation

public enum GrokOfficialCredentialStatus: Sendable, Equatable {
    case missing
    case malformed
    case unreadable
    case apiKeyOnly
    case unsupported
    case authenticated(GrokCredentialIdentity)
    case requiresReauthentication(GrokCredentialIdentity)

    public var identity: GrokCredentialIdentity? {
        switch self {
        case let .authenticated(identity), let .requiresReauthentication(identity):
            identity
        case .missing, .malformed, .unreadable, .apiKeyOnly, .unsupported:
            nil
        }
    }
}

public struct GrokManagedAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sortIndex: Int
    public var identity: GrokCredentialIdentity
    public var alias: String?
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var lastQuotaAt: Date?
    public var requiresReauth: Bool
    public var lastError: String?
    public var cachedQuota: GrokQuotaSnapshot?

    public init(
        id: String,
        sortIndex: Int = 0,
        identity: GrokCredentialIdentity,
        alias: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        lastQuotaAt: Date? = nil,
        requiresReauth: Bool = false,
        lastError: String? = nil,
        cachedQuota: GrokQuotaSnapshot? = nil)
    {
        self.id = id
        self.sortIndex = sortIndex
        self.identity = identity
        self.alias = alias
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastQuotaAt = lastQuotaAt
        self.requiresReauth = requiresReauth
        self.lastError = lastError
        self.cachedQuota = cachedQuota
    }

    public var email: String? { identity.email }
    public var userID: String? { identity.userID }
    public var teamName: String? { identity.teamName }

    public var resolvedDisplayName: String {
        firstNonEmpty(alias, identity.resolvedDisplayName) ?? id
    }

    public func applying(snapshot: GrokQuotaSnapshot) -> Self {
        var copy = self
        copy.cachedQuota = snapshot
        copy.lastQuotaAt = snapshot.updatedAt
        copy.requiresReauth = false
        copy.lastError = nil
        return copy
    }

    public func applying(error: String, requiresReauth: Bool) -> Self {
        var copy = self
        copy.lastError = error
        copy.requiresReauth = requiresReauth
        return copy
    }
}

public struct GrokAccountIndex: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var currentAccountID: String?
    public var accounts: [GrokManagedAccount]

    public init(
        version: Int = GrokAccountIndex.currentVersion,
        currentAccountID: String? = nil,
        accounts: [GrokManagedAccount] = [])
    {
        self.version = version
        self.currentAccountID = currentAccountID
        self.accounts = accounts
    }

    public func account(id: String) -> GrokManagedAccount? {
        accounts.first { $0.id == id }
    }

    public func orderedAccounts() -> [GrokManagedAccount] {
        accounts.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.resolvedDisplayName.localizedCaseInsensitiveCompare($1.resolvedDisplayName) == .orderedAscending
        }
    }

    public mutating func upsert(_ account: GrokManagedAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }
}

public struct GrokAccountState: Sendable, Equatable {
    public var officialCredentialStatus: GrokOfficialCredentialStatus
    public var currentAccountID: String?
    public var accounts: [GrokManagedAccount]
    public var officialIdentityChangedExternally: Bool

    public init(
        officialCredentialStatus: GrokOfficialCredentialStatus,
        currentAccountID: String?,
        accounts: [GrokManagedAccount],
        officialIdentityChangedExternally: Bool = false)
    {
        self.officialCredentialStatus = officialCredentialStatus
        self.currentAccountID = currentAccountID
        self.accounts = accounts
        self.officialIdentityChangedExternally = officialIdentityChangedExternally
    }
}

public enum GrokAccountCommand: Sendable, Equatable {
    case loginOAuth
    case importOfficial
    case makeCurrent(id: String, allowWhileRunning: Bool)
    case remove(id: String)
    case setAlias(id: String, alias: String?)
    case reorder(ids: [String])
}

public enum GrokRefreshTarget: Sendable, Equatable {
    case current
    case account(id: String)
    case all
}

public struct GrokRefreshOutcome: Sendable, Equatable {
    public var accountID: String
    public var snapshot: GrokQuotaSnapshot?
    public var error: GrokAccountError?
    public var retainedStaleSnapshot: Bool

    public init(
        accountID: String,
        snapshot: GrokQuotaSnapshot? = nil,
        error: GrokAccountError? = nil,
        retainedStaleSnapshot: Bool = false)
    {
        self.accountID = accountID
        self.snapshot = snapshot
        self.error = error
        self.retainedStaleSnapshot = retainedStaleSnapshot
    }
}

public struct GrokRefreshReport: Sendable, Equatable {
    public var target: GrokRefreshTarget
    public var outcomes: [GrokRefreshOutcome]
    public var startedAt: Date
    public var finishedAt: Date

    public init(
        target: GrokRefreshTarget,
        outcomes: [GrokRefreshOutcome],
        startedAt: Date,
        finishedAt: Date)
    {
        self.target = target
        self.outcomes = outcomes
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public enum GrokAccountError: Error, Sendable, Equatable {
    case cliNotInstalled
    case cliTooOld(String)
    case officialCredentialMissing
    case officialCredentialMalformed
    case apiKeyOnlyNotManageable
    case noManagedCredential
    case accountNotFound(String)
    case credentialMissing(String)
    case credentialIdentityMismatch(String)
    case currentAccountCannotBeRemoved(String)
    case grokProcessesRunning([Int32])
    case authFileLocked
    case loginCancelled
    case loginFailed(String)
    case refreshFailed(accountID: String, message: String)
    case unsupportedIndexVersion(Int)
    case invalidCredential
    case io(String)
    case partialWrite(String)
}
