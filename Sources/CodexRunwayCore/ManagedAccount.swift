import Foundation

public enum ManagedAuthMode: String, Codable, Sendable, Equatable {
    case oauth
    case apiKey
}

/// One quota meter row cached for multi-account UI (mirrors main-window meters).
public struct CachedQuotaMeterRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Primary/secondary window length in minutes when known (drives 5h/weekly labels).
    public var windowMinutes: Int?
    /// Named additional limit from API (e.g. model-specific windows).
    public var name: String?
    public var usedPercent: Int
    public var resetsAt: Date?

    public init(
        id: String,
        windowMinutes: Int? = nil,
        name: String? = nil,
        usedPercent: Int,
        resetsAt: Date? = nil)
    {
        self.id = id
        self.windowMinutes = windowMinutes
        self.name = name
        self.usedPercent = max(0, min(100, usedPercent))
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    /// Same title rules as the main popover quota section.
    public func title(l10n: L10n) -> String {
        if let name, !name.isEmpty {
            return name
        }
        switch windowMinutes {
        case 300:
            return l10n.text(.fiveHourUsage)
        case 10_080:
            return l10n.text(.weeklyUsage)
        default:
            return l10n.text(.quota)
        }
    }
}

/// Cached quota fields for sidebar / multi-account list (no secrets).
public struct CachedAccountQuota: Codable, Sendable, Equatable {
    public var plan: String?
    public var primaryUsedPercent: Int
    public var primaryResetsAt: Date?
    public var primaryWindowMinutes: Int?
    public var secondaryUsedPercent: Int?
    public var secondaryResetsAt: Date?
    public var secondaryWindowMinutes: Int?
    /// Additional named windows (model limits, etc.), same order as the main panel.
    public var additionalMeters: [CachedQuotaMeterRow]
    public var updatedAt: Date

    public init(
        plan: String? = nil,
        primaryUsedPercent: Int,
        primaryResetsAt: Date? = nil,
        primaryWindowMinutes: Int? = nil,
        secondaryUsedPercent: Int? = nil,
        secondaryResetsAt: Date? = nil,
        secondaryWindowMinutes: Int? = nil,
        additionalMeters: [CachedQuotaMeterRow] = [],
        updatedAt: Date = Date())
    {
        self.plan = plan
        self.primaryUsedPercent = max(0, min(100, primaryUsedPercent))
        self.primaryResetsAt = primaryResetsAt
        self.primaryWindowMinutes = primaryWindowMinutes
        self.secondaryUsedPercent = secondaryUsedPercent.map { max(0, min(100, $0)) }
        self.secondaryResetsAt = secondaryResetsAt
        self.secondaryWindowMinutes = secondaryWindowMinutes
        self.additionalMeters = additionalMeters
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case plan
        case primaryUsedPercent
        case primaryResetsAt
        case primaryWindowMinutes
        case secondaryUsedPercent
        case secondaryResetsAt
        case secondaryWindowMinutes
        case additionalMeters
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        primaryUsedPercent = max(0, min(100, try container.decode(Int.self, forKey: .primaryUsedPercent)))
        primaryResetsAt = try container.decodeIfPresent(Date.self, forKey: .primaryResetsAt)
        primaryWindowMinutes = try container.decodeIfPresent(Int.self, forKey: .primaryWindowMinutes)
        secondaryUsedPercent = try container.decodeIfPresent(Int.self, forKey: .secondaryUsedPercent).map { max(0, min(100, $0)) }
        secondaryResetsAt = try container.decodeIfPresent(Date.self, forKey: .secondaryResetsAt)
        secondaryWindowMinutes = try container.decodeIfPresent(Int.self, forKey: .secondaryWindowMinutes)
        additionalMeters = try container.decodeIfPresent([CachedQuotaMeterRow].self, forKey: .additionalMeters) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public static func make(from snapshot: QuotaSnapshot) -> CachedAccountQuota {
        let additional = snapshot.additionalWindows.enumerated().map { index, named in
            CachedQuotaMeterRow(
                id: "additional-\(index)-\(named.name)",
                windowMinutes: named.window.windowMinutes,
                name: named.name,
                usedPercent: named.window.usedPercent,
                resetsAt: named.window.resetsAt)
        }
        return CachedAccountQuota(
            plan: snapshot.plan,
            primaryUsedPercent: snapshot.primary.usedPercent,
            primaryResetsAt: snapshot.primary.resetsAt,
            primaryWindowMinutes: snapshot.primary.windowMinutes,
            secondaryUsedPercent: snapshot.secondary?.usedPercent,
            secondaryResetsAt: snapshot.secondary?.resetsAt,
            secondaryWindowMinutes: snapshot.secondary?.windowMinutes,
            additionalMeters: additional,
            updatedAt: snapshot.updatedAt)
    }

    public var primaryRemainingPercent: Int {
        max(0, 100 - primaryUsedPercent)
    }

    public var secondaryRemainingPercent: Int? {
        secondaryUsedPercent.map { max(0, 100 - $0) }
    }

    /// Display rows aligned with main-window quota meters (primary, secondary, then additional).
    public func meterRows() -> [CachedQuotaMeterRow] {
        var rows = [
            CachedQuotaMeterRow(
                id: "primary",
                windowMinutes: primaryWindowMinutes,
                name: nil,
                usedPercent: primaryUsedPercent,
                resetsAt: primaryResetsAt),
        ]
        if let secondaryUsedPercent {
            rows.append(
                CachedQuotaMeterRow(
                    id: "secondary",
                    windowMinutes: secondaryWindowMinutes ?? 10_080,
                    name: nil,
                    usedPercent: secondaryUsedPercent,
                    resetsAt: secondaryResetsAt))
        }
        rows.append(contentsOf: additionalMeters)
        return rows
    }
}

/// Non-secret metadata for a managed Codex account.
public struct ManagedAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sortIndex: Int
    public var authMode: ManagedAuthMode
    public var email: String?
    public var username: String?
    public var userId: String?
    public var subjectId: String?
    public var accountId: String?
    public var workspaceName: String?
    public var displayName: String
    public var alias: String?
    public var note: String?
    public var planType: String?
    public var subscriptionExpiresAt: Date?
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var lastQuotaAt: Date?
    public var requiresReauth: Bool
    public var lastError: String?
    public var cachedQuota: CachedAccountQuota?

    public init(
        id: String,
        sortIndex: Int = 0,
        authMode: ManagedAuthMode = .oauth,
        email: String? = nil,
        username: String? = nil,
        userId: String? = nil,
        subjectId: String? = nil,
        accountId: String? = nil,
        workspaceName: String? = nil,
        displayName: String,
        alias: String? = nil,
        note: String? = nil,
        planType: String? = nil,
        subscriptionExpiresAt: Date? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        lastQuotaAt: Date? = nil,
        requiresReauth: Bool = false,
        lastError: String? = nil,
        cachedQuota: CachedAccountQuota? = nil)
    {
        self.id = id
        self.sortIndex = sortIndex
        self.authMode = authMode
        self.email = email
        self.username = username
        self.userId = userId
        self.subjectId = subjectId
        self.accountId = accountId
        self.workspaceName = workspaceName
        self.displayName = displayName
        self.alias = alias
        self.note = note
        self.planType = planType
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastQuotaAt = lastQuotaAt
        self.requiresReauth = requiresReauth
        self.lastError = lastError
        self.cachedQuota = cachedQuota
    }

    public var resolvedDisplayName: String {
        firstNonEmpty(alias, displayName, email, username, accountId.map { Self.shorten($0) }) ?? id
    }

    public var subscriptionTier: CodexSubscriptionTier {
        CodexSubscriptionTier.resolve(planType: planType ?? cachedQuota?.plan, fallbackPlanType: nil)
    }

    public var identityMarkerUserId: String? {
        firstNonEmpty(userId)
    }

    public var identityMarkerWorkspaceId: String? {
        firstNonEmpty(accountId)
    }

    public var displaysWorkspaceIdentity: Bool {
        switch subscriptionTier {
        case .team, .business, .enterprise, .edu:
            return true
        default:
            return false
        }
    }

    public static func make(
        id: String? = nil,
        auth: CodexAuth,
        sortIndex: Int = 0,
        alias: String? = nil,
        note: String? = nil,
        quotaPlan: String? = nil,
        now: Date = Date()) -> ManagedAccount
    {
        if auth.isAPIKeyAuth {
            let key = auth.openAIAPIKey ?? ""
            let fingerprint = AccountIdentity.apiKeyFingerprint(key)
            let accountId = "api-\(fingerprint)"
            return ManagedAccount(
                id: id ?? accountId,
                sortIndex: sortIndex,
                authMode: .apiKey,
                email: nil,
                username: nil,
                userId: nil,
                subjectId: nil,
                accountId: accountId,
                workspaceName: nil,
                displayName: "API ···\(fingerprint.suffix(4))",
                alias: alias,
                note: note,
                planType: firstNonEmpty(quotaPlan, auth.planType, "api"),
                subscriptionExpiresAt: nil,
                createdAt: now,
                lastUsedAt: nil,
                lastQuotaAt: nil,
                requiresReauth: false,
                lastError: nil,
                cachedQuota: nil)
        }

        let display = CodexAccountDisplay.make(auth: auth, quotaPlan: quotaPlan, now: now)
        let idClaims = CodexIdentityClaims.decode(auth.tokens.idToken)
        let accessClaims = CodexIdentityClaims.decode(auth.tokens.accessToken)
        let stableId = id
            ?? AccountIdentity.managedAccountId(for: auth)
        // Prefer live quota plan, then JWT claims, then auth-file fields — never invent from nowhere.
        let resolvedPlan = firstNonEmpty(
            quotaPlan,
            idClaims?.planType,
            accessClaims?.planType,
            auth.authFilePlanType,
            auth.planType)
        return ManagedAccount(
            id: stableId,
            sortIndex: sortIndex,
            authMode: .oauth,
            email: display.email,
            username: display.username,
            userId: AccountIdentity.oauthUserId(for: auth),
            subjectId: AccountIdentity.oauthSubjectId(for: auth),
            accountId: display.accountId,
            workspaceName: AccountIdentity.oauthWorkspaceName(for: auth),
            displayName: display.displayName.isEmpty ? stableId : display.displayName,
            alias: alias,
            note: note,
            planType: resolvedPlan,
            subscriptionExpiresAt: display.subscriptionExpiresAt,
            createdAt: now,
            lastUsedAt: nil,
            lastQuotaAt: nil,
            requiresReauth: false,
            lastError: nil,
            cachedQuota: nil)
    }

    public func withIdentity(from auth: CodexAuth, quotaPlan: String? = nil, now: Date = Date()) -> ManagedAccount {
        var copy = self
        let rebuilt = ManagedAccount.make(
            id: id,
            auth: auth,
            sortIndex: sortIndex,
            alias: alias,
            note: note,
            quotaPlan: quotaPlan,
            now: now)
        copy.authMode = rebuilt.authMode
        copy.email = rebuilt.email
        copy.username = rebuilt.username
        copy.userId = rebuilt.userId
        copy.subjectId = rebuilt.subjectId
        copy.accountId = rebuilt.accountId
        copy.workspaceName = firstNonEmpty(rebuilt.workspaceName, workspaceName)
        if alias == nil {
            copy.displayName = rebuilt.displayName
        }
        // Fresh auth/JWT plan must beat stale metadata when no explicit quota plan is supplied.
        copy.planType = firstNonEmpty(quotaPlan, rebuilt.planType, planType)
        copy.subscriptionExpiresAt = rebuilt.subscriptionExpiresAt
        return copy
    }

    public func applying(quota: QuotaSnapshot) -> ManagedAccount {
        var copy = self
        copy.cachedQuota = CachedAccountQuota.make(from: quota)
        copy.lastQuotaAt = quota.updatedAt
        if let plan = firstNonEmpty(quota.plan) {
            copy.planType = plan
        }
        copy.requiresReauth = false
        copy.lastError = nil
        return copy
    }

    public func applying(error: String, requiresReauth: Bool) -> ManagedAccount {
        var copy = self
        copy.lastError = error
        copy.requiresReauth = requiresReauth
        return copy
    }

    private static func shorten(_ value: String) -> String {
        guard value.count > 9 else { return value }
        return "\(value.prefix(5))...\(value.suffix(4))"
    }
}

public enum AccountIdentity {
    public static func apiKeyFingerprint(_ apiKey: String) -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return stableHash(trimmed)
    }

    public static func oauthFingerprint(_ auth: CodexAuth) -> String {
        if !auth.tokens.refreshToken.isEmpty {
            return "rt-\(stableHash(auth.tokens.refreshToken))"
        }
        if !auth.tokens.accessToken.isEmpty {
            return "at-\(stableHash(auth.tokens.accessToken))"
        }
        return "unknown-\(stableHash(UUID().uuidString))"
    }

    static func oauthUserId(for auth: CodexAuth) -> String? {
        oauthIdentity(for: auth).userId
    }

    static func oauthSubjectId(for auth: CodexAuth) -> String? {
        oauthIdentity(for: auth).subjectId
    }

    /// Workspace used to route authenticated ChatGPT requests. The top-level auth value is the
    /// selected workspace and must win even when stale JWT claims disagree with it.
    static func routingWorkspaceId(for auth: CodexAuth) -> String? {
        oauthIdentity(for: auth).routingWorkspaceId
    }

    static func oauthEmail(for auth: CodexAuth) -> String? {
        oauthIdentity(for: auth).email
    }

    static func oauthWorkspaceName(for auth: CodexAuth) -> String? {
        oauthIdentity(for: auth).workspaceName
    }

    public static func managedAccountId(for auth: CodexAuth) -> String {
        if auth.isAPIKeyAuth, let key = auth.openAIAPIKey {
            return "api-\(apiKeyFingerprint(key))"
        }
        return "oauth-\(stableHash(matchKey(for: auth)))"
    }

    public static func matchKey(for account: ManagedAccount) -> String {
        if account.authMode == .apiKey, let accountId = firstNonEmpty(account.accountId) {
            return "id:\(accountId.lowercased())"
        }
        if let subjectId = normalizedIdentifier(account.subjectId),
           let accountId = normalizedIdentifier(account.accountId)
        {
            return "oauth:subject:\(subjectId)|account:\(accountId)"
        }
        if let userId = normalizedIdentifier(account.userId),
           let accountId = normalizedIdentifier(account.accountId)
        {
            return "oauth:user:\(userId)|account:\(accountId)"
        }
        if account.userId == nil, account.subjectId == nil,
           let email = normalizedEmail(account.email),
           let accountId = normalizedIdentifier(account.accountId)
        {
            return "oauth:email:\(email)|account:\(accountId)"
        }
        return "row:\(account.id)"
    }

    public static func matchKey(for auth: CodexAuth) -> String {
        if auth.isAPIKeyAuth, let key = auth.openAIAPIKey {
            return "id:api-\(apiKeyFingerprint(key))"
        }
        let identity = oauthIdentity(for: auth)
        if identity.hasUserConflict || identity.hasWorkspaceConflict {
            return credentialMatchKey(for: auth, workspaceId: identity.routingWorkspaceId)
        }
        if let subjectId = identity.subjectId, let accountId = identity.routingWorkspaceId {
            return "oauth:subject:\(subjectId)|account:\(accountId)"
        }
        if let userId = identity.userId, let accountId = identity.routingWorkspaceId {
            return "oauth:user:\(userId)|account:\(accountId)"
        }
        if identity.userId == nil, identity.subjectId == nil,
           let email = identity.email,
           let accountId = identity.routingWorkspaceId
        {
            return "oauth:email:\(email)|account:\(accountId)"
        }
        return credentialMatchKey(for: auth, workspaceId: identity.routingWorkspaceId)
    }

    /// Matches current compound identities while allowing a legacy row without `userId`
    /// to be upgraded by the same email + workspace credential. Never falls back to the
    /// workspace id alone when either side has a user-level identity.
    public static func matches(account: ManagedAccount, auth: CodexAuth) -> Bool {
        if account.authMode == .apiKey || auth.isAPIKeyAuth {
            return matchKey(for: account) == matchKey(for: auth)
        }

        let identity = oauthIdentity(for: auth)
        if identity.hasUserConflict || identity.hasWorkspaceConflict {
            return account.id == managedAccountId(for: auth)
        }

        let accountWorkspaceId = normalizedIdentifier(account.accountId)
        let authWorkspaceId = identity.routingWorkspaceId
        let accountEmail = normalizedEmail(account.email)
        let authEmail = identity.email

        guard let accountWorkspaceId, let authWorkspaceId,
              accountWorkspaceId == authWorkspaceId
        else {
            return account.id == managedAccountId(for: auth)
        }

        let accountSubjectId = normalizedIdentifier(account.subjectId)
        let accountUserId = normalizedIdentifier(account.userId)
        if let accountSubjectId, let authSubjectId = identity.subjectId {
            return accountSubjectId == authSubjectId
        }
        if let accountUserId, let authUserId = identity.userId {
            return accountUserId == authUserId
        }
        if accountSubjectId != nil || accountUserId != nil { return false }
        if let accountEmail, let authEmail {
            return accountEmail == authEmail
        }

        return account.id == managedAccountId(for: auth)
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        firstNonEmpty(value)
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        firstNonEmpty(value)?.lowercased()
    }

    private static func normalizedIdentifiers(_ values: [String?]) -> [String] {
        Array(Set(values.compactMap(normalizedIdentifier))).sorted()
    }

    private static func credentialMatchKey(for auth: CodexAuth, workspaceId: String?) -> String {
        let credential = oauthFingerprint(auth)
        if let workspaceId = normalizedIdentifier(workspaceId) {
            return "oauth:workspace:\(workspaceId)|credential:\(credential)"
        }
        return "oauth:credential:\(credential)"
    }

    private static func oauthIdentity(for auth: CodexAuth) -> OAuthIdentity {
        let idClaims = CodexIdentityClaims.decode(auth.tokens.idToken)
        let accessClaims = CodexIdentityClaims.decode(auth.tokens.accessToken)
        let explicitUserIds = normalizedIdentifiers([idClaims?.userId, accessClaims?.userId])
        let subjectIds = normalizedIdentifiers([idClaims?.subject, accessClaims?.subject])
        let emails = Array(Set([idClaims?.email, accessClaims?.email].compactMap(normalizedEmail))).sorted()
        let topLevelWorkspaceId = normalizedIdentifier(auth.tokens.accountId)
        let jwtWorkspaceIds = normalizedIdentifiers([idClaims?.accountId, accessClaims?.accountId])
        let organizationIds = normalizedIdentifiers([idClaims?.organizationId, accessClaims?.organizationId])

        let routingWorkspaceId: String? = if let topLevelWorkspaceId {
            topLevelWorkspaceId
        } else if jwtWorkspaceIds.count == 1 {
            jwtWorkspaceIds[0]
        } else if jwtWorkspaceIds.isEmpty, organizationIds.count == 1 {
            organizationIds[0]
        } else {
            nil
        }

        let topLevelDisagreesWithJWT = topLevelWorkspaceId.map { selected in
            jwtWorkspaceIds.contains { $0 != selected }
        } ?? false
        let hasWorkspaceConflict = jwtWorkspaceIds.count > 1
            || topLevelDisagreesWithJWT
            || (topLevelWorkspaceId == nil && jwtWorkspaceIds.isEmpty && organizationIds.count > 1)
        let organizationId = organizationIds.count == 1 ? organizationIds[0] : nil
        let organizationNames = normalizedIdentifiers([
            idClaims?.organizationId == organizationId ? idClaims?.organizationName : nil,
            accessClaims?.organizationId == organizationId ? accessClaims?.organizationName : nil,
        ])
        let workspaceName: String? = if organizationId == routingWorkspaceId, organizationNames.count == 1 {
            organizationNames[0]
        } else {
            nil
        }
        let userId: String? = if explicitUserIds.isEmpty {
            subjectIds.count == 1 ? subjectIds[0] : nil
        } else {
            explicitUserIds.count == 1 ? explicitUserIds[0] : nil
        }

        return OAuthIdentity(
            userId: userId,
            subjectId: subjectIds.count == 1 ? subjectIds[0] : nil,
            email: emails.count == 1 ? emails[0] : nil,
            routingWorkspaceId: routingWorkspaceId,
            workspaceName: workspaceName,
            hasUserConflict: explicitUserIds.count > 1 || subjectIds.count > 1,
            hasWorkspaceConflict: hasWorkspaceConflict)
    }

    private struct OAuthIdentity {
        var userId: String?
        var subjectId: String?
        var email: String?
        var routingWorkspaceId: String?
        var workspaceName: String?
        var hasUserConflict: Bool
        var hasWorkspaceConflict: Bool
    }

    /// Stable short hex hash (not cryptographic; for ids/dedup only).
    public static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 5_381
        for byte in value.utf8 {
            hash = 127 &* hash &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

public struct AccountIndex: Codable, Sendable, Equatable {
    public var version: Int
    public var activeAccountId: String?
    public var accounts: [ManagedAccount]

    public static let currentVersion = 1

    public init(version: Int = AccountIndex.currentVersion, activeAccountId: String? = nil, accounts: [ManagedAccount] = []) {
        self.version = version
        self.activeAccountId = activeAccountId
        self.accounts = accounts
    }

    /// Active first, then user sortIndex, then display name.
    public func orderedForSidebar() -> [ManagedAccount] {
        let active = activeAccountId
        return accounts.sorted { lhs, rhs in
            let lActive = lhs.id == active
            let rActive = rhs.id == active
            if lActive != rActive { return lActive && !rActive }
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.resolvedDisplayName.localizedCaseInsensitiveCompare(rhs.resolvedDisplayName) == .orderedAscending
        }
    }

    public func account(id: String) -> ManagedAccount? {
        accounts.first { $0.id == id }
    }

    public mutating func upsert(_ account: ManagedAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    public mutating func remove(id: String) {
        accounts.removeAll { $0.id == id }
        if activeAccountId == id {
            activeAccountId = accounts.sorted { $0.sortIndex < $1.sortIndex }.first?.id
        }
    }

    public mutating func reindexSortOrder(_ orderedIds: [String]) {
        var next = 0
        for id in orderedIds {
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { continue }
            accounts[index].sortIndex = next
            next += 1
        }
        for index in accounts.indices where !orderedIds.contains(accounts[index].id) {
            accounts[index].sortIndex = next
            next += 1
        }
    }
}
