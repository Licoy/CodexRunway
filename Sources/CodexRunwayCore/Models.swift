import Foundation

public struct CodexAuth: Codable, Sendable, Equatable {
    public var authMode: String?
    public var tokens: Tokens
    public var lastRefresh: String?
    public var planType: String?
    public var authFilePlanType: String?
    /// Present for API-key style auth files (and some mixed official files).
    public var openAIAPIKey: String?

    public struct Tokens: Codable, Sendable, Equatable {
        public var idToken: String?
        public var accessToken: String
        public var refreshToken: String
        public var accountId: String?

        public init(idToken: String? = nil, accessToken: String, refreshToken: String, accountId: String?) {
            self.idToken = idToken
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.accountId = accountId
        }

        public static let empty = Tokens(idToken: nil, accessToken: "", refreshToken: "", accountId: nil)

        public var hasOAuthTokens: Bool {
            !accessToken.isEmpty || !refreshToken.isEmpty
        }

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountId = "account_id"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
            accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
            accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // Codex auth.json expects refresh_token key to exist (may be empty for session tokens).
            if let idToken, !idToken.isEmpty {
                try container.encode(idToken, forKey: .idToken)
            }
            try container.encode(accessToken, forKey: .accessToken)
            try container.encode(refreshToken, forKey: .refreshToken)
            if let accountId, !accountId.isEmpty {
                try container.encode(accountId, forKey: .accountId)
            }
        }
    }

    /// Whether this credential is safe to install as `~/.codex/auth.json` for the Codex app/CLI.
    /// Access-token-only session credentials (e.g. chatgpt.com/api/auth/session) are usable while
    /// the access JWT is still valid — matching other multi-account tools.
    public enum LoginUsability: Sendable, Equatable {
        case usable
        /// Access token is expired (or missing) and there is no refresh_token to renew it.
        case expiredAccessWithoutRefresh
        case invalidTokens
    }

    public var loginUsability: LoginUsability {
        if isAPIKeyAuth {
            if let key = openAIAPIKey, key.count >= 8 { return .usable }
            return .invalidTokens
        }
        // Reject placeholders / truncated junk written by failed switches.
        guard tokens.accessToken.count >= 40 else { return .invalidTokens }
        if canRefreshOAuth {
            // Real refresh tokens are long; short strings are corrupt.
            if tokens.refreshToken.count < 20 { return .invalidTokens }
            return .usable
        }
        // Session-style: access only. Allow switch while JWT still valid.
        if TokenInspector.isExpired(tokens.accessToken) {
            return .expiredAccessWithoutRefresh
        }
        return .usable
    }

    /// True when this is a browser-session style credential (access JWT, no refresh).
    public var isAccessTokenOnly: Bool {
        !isAPIKeyAuth && tokens.accessToken.count >= 40 && tokens.refreshToken.isEmpty
    }

    public init(
        authMode: String?,
        tokens: Tokens,
        lastRefresh: String?,
        planType: String? = nil,
        authFilePlanType: String? = nil,
        openAIAPIKey: String? = nil)
    {
        self.authMode = authMode
        self.tokens = tokens
        self.lastRefresh = lastRefresh
        self.planType = planType
        self.authFilePlanType = authFilePlanType
        self.openAIAPIKey = openAIAPIKey
    }

    /// API-key-only credential used for managed accounts and CLI switch writes.
    public static func apiKey(apiKey: String, baseURLHint _: String? = nil) -> CodexAuth {
        CodexAuth(
            authMode: "apikey",
            tokens: .empty,
            lastRefresh: nil,
            planType: "api",
            authFilePlanType: "api",
            openAIAPIKey: apiKey)
    }

    public var isAPIKeyAuth: Bool {
        if let key = openAIAPIKey, !key.isEmpty, !tokens.hasOAuthTokens { return true }
        let mode = (authMode ?? "").lowercased()
        return mode == "apikey" || mode == "api_key" || mode == "api-key"
    }

    public var canRefreshOAuth: Bool {
        !tokens.refreshToken.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
        case lastRefresh = "last_refresh"
        case planType = "plan_type"
        case authFilePlanType = "auth_file_plan_type"
        case openAIAPIKey = "OPENAI_API_KEY"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authMode = try container.decodeIfPresent(String.self, forKey: .authMode)
        tokens = try container.decodeIfPresent(Tokens.self, forKey: .tokens) ?? .empty
        lastRefresh = try container.decodeIfPresent(String.self, forKey: .lastRefresh)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        authFilePlanType = try container.decodeIfPresent(String.self, forKey: .authFilePlanType)
        openAIAPIKey = try container.decodeIfPresent(String.self, forKey: .openAIAPIKey)
        if tokens.accessToken.isEmpty, tokens.refreshToken.isEmpty, openAIAPIKey == nil {
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath, debugDescription: "auth.json missing tokens and OPENAI_API_KEY"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Match the official auth.json shape Codex expects. Do not emit our private
        // plan metadata fields into the file Codex watches.
        try container.encodeIfPresent(authMode ?? (isAPIKeyAuth ? "apikey" : "chatgpt"), forKey: .authMode)
        if isAPIKeyAuth {
            try container.encodeIfPresent(openAIAPIKey, forKey: .openAIAPIKey)
        } else {
            try container.encode(tokens, forKey: .tokens)
            try container.encodeIfPresent(lastRefresh, forKey: .lastRefresh)
            // Keep OPENAI_API_KEY only when the original mixed auth file had one.
            try container.encodeIfPresent(openAIAPIKey, forKey: .openAIAPIKey)
        }
    }

    /// JSON object suitable for official `auth.json` (no runway-only keys).
    public func officialAuthJSONObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "auth encode failed"))
        }
        return object
    }

    public var redactedDescription: String {
        let keyFlag = openAIAPIKey == nil ? "none" : "<redacted>"
        return "CodexAuth(authMode: \(authMode ?? "unknown"), accountId: \(tokens.accountId ?? "none"), idToken: <redacted>, accessToken: <redacted>, refreshToken: <redacted>, OPENAI_API_KEY: \(keyFlag))"
    }

    public mutating func mergeRefreshResponse(_ data: Data, now: Date = Date()) throws {
        let response = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        if let idToken = response.idToken, !idToken.isEmpty {
            tokens.idToken = idToken
        }
        tokens.accessToken = response.accessToken
        if let refreshToken = response.refreshToken, !refreshToken.isEmpty {
            tokens.refreshToken = refreshToken
        }
        lastRefresh = RunwayDates.string(now)
    }
}

struct TokenRefreshResponse: Decodable {
    var idToken: String?
    var accessToken: String
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

public enum TokenInspector {
    public static func isExpired(_ jwt: String, now: Date = Date(), skewSeconds: TimeInterval = 60) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64URLEncoded: String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? Double
        else { return true }
        return Date(timeIntervalSince1970: exp).timeIntervalSince(now) <= skewSeconds
    }
}

public struct CodexIdentityClaims: Sendable, Equatable {
    public var email: String?
    public var username: String?
    public var subject: String?
    public var planType: String?
    public var accountId: String?
    /// Billing period end from JWT `chatgpt_subscription_active_until` when present.
    public var subscriptionActiveUntil: Date?

    public static func decode(_ jwt: String?) -> CodexIdentityClaims? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64URLEncoded: String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let profile = object["https://api.openai.com/profile"] as? [String: Any]
        let auth = object["https://api.openai.com/auth"] as? [String: Any]
        return CodexIdentityClaims(
            email: firstNonEmpty(object["email"] as? String, profile?["email"] as? String),
            username: firstNonEmpty(object["preferred_username"] as? String, object["name"] as? String),
            subject: firstNonEmpty(object["sub"] as? String),
            planType: firstNonEmpty(auth?["chatgpt_plan_type"] as? String),
            accountId: firstNonEmpty(
                auth?["chatgpt_account_id"] as? String,
                auth?["account_id"] as? String),
            subscriptionActiveUntil: Self.parseDate(auth?["chatgpt_subscription_active_until"]))
    }

    private static func parseDate(_ value: Any?) -> Date? {
        switch value {
        case let text as String:
            return RunwayDates.parse(text)
        case let seconds as Double:
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        case let seconds as Int:
            return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
        case let number as NSNumber:
            let seconds = number.doubleValue
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        default:
            return nil
        }
    }
}

public enum CodexSubscriptionTier: Sendable, Equatable {
    case free
    case plus
    case pro5x
    case pro20x
    case business
    case team
    case enterprise
    case edu
    case api
    case unknown

    public static func resolve(planType: String?, fallbackPlanType: String?) -> CodexSubscriptionTier {
        guard let raw = firstNonEmpty(planType, fallbackPlanType)?.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        else { return .unknown }

        if raw == "prolite" || raw == "pro-lite" || raw == "pro-5x" || raw == "codex-pro-5x" {
            return .pro5x
        }
        if raw == "promax" || raw == "pro-max" || raw == "pro-20x" || raw == "codex-pro-20x" {
            return .pro20x
        }
        if raw.contains("enterprise") { return .enterprise }
        if raw.contains("business") { return .business }
        if raw.contains("team") { return .team }
        if raw.contains("edu") { return .edu }
        if raw.contains("api") { return .api }
        if raw.contains("plus") { return .plus }
        if raw.contains("pro") { return .pro20x }
        if raw.contains("free") { return .free }
        return .unknown
    }
}

public struct CodexAccountDisplay: Sendable, Equatable {
    public var isAuthenticated: Bool
    public var displayName: String
    public var email: String?
    public var username: String?
    public var accountId: String?
    public var subscriptionTier: CodexSubscriptionTier
    /// Subscription billing period end from local JWT claims when available.
    /// Paid plans with a stale past JWT date are advanced month-by-month to the next future period end.
    public var subscriptionExpiresAt: Date?

    public static func make(auth: CodexAuth?, quotaPlan: String?, now: Date = Date()) -> CodexAccountDisplay {
        guard let auth else {
            return CodexAccountDisplay(
                isAuthenticated: false,
                displayName: "",
                email: nil,
                username: nil,
                accountId: nil,
                subscriptionTier: .unknown,
                subscriptionExpiresAt: nil)
        }
        let idClaims = CodexIdentityClaims.decode(auth.tokens.idToken)
        let accessClaims = CodexIdentityClaims.decode(auth.tokens.accessToken)
        let email = firstNonEmpty(idClaims?.email, accessClaims?.email)
        let username = firstNonEmpty(idClaims?.username, accessClaims?.username, idClaims?.subject, accessClaims?.subject)
        let accountId = firstNonEmpty(idClaims?.accountId, accessClaims?.accountId, auth.tokens.accountId)
        let plan = firstNonEmpty(quotaPlan, idClaims?.planType, accessClaims?.planType, auth.authFilePlanType, auth.planType)
        let tier = CodexSubscriptionTier.resolve(planType: plan, fallbackPlanType: nil)
        let rawExpiry = idClaims?.subscriptionActiveUntil ?? accessClaims?.subscriptionActiveUntil
        return CodexAccountDisplay(
            isAuthenticated: true,
            displayName: firstNonEmpty(email, username, shortenedAccountId(accountId)) ?? "",
            email: email,
            username: username,
            accountId: accountId,
            subscriptionTier: tier,
            subscriptionExpiresAt: resolvedSubscriptionExpiresAt(raw: rawExpiry, tier: tier, now: now))
    }

    /// JWT `chatgpt_subscription_active_until` is often not refreshed after renewals.
    /// When the plan is still a paid tier but the claim is already in the past, advance by
    /// whole calendar months (UTC, matching the claim timezone) until the next future end.
    public static func resolvedSubscriptionExpiresAt(
        raw: Date?,
        tier: CodexSubscriptionTier,
        now: Date = Date())
        -> Date?
    {
        guard let raw else { return nil }
        if raw >= now { return raw }
        guard tier.projectsBillingCycleWhenStale else { return raw }
        return projectedNextPeriodEnd(from: raw, now: now)
    }

    private static func projectedNextPeriodEnd(from raw: Date, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")!
        var projected = raw
        // Hard cap avoids pathological loops if date math fails.
        for _ in 0..<48 {
            guard projected < now else { break }
            guard let next = calendar.date(byAdding: .month, value: 1, to: projected), next > projected else {
                break
            }
            projected = next
        }
        return projected
    }

    private static func shortenedAccountId(_ value: String?) -> String? {
        guard let value = firstNonEmpty(value) else { return nil }
        guard value.count > 9 else { return value }
        return "\(value.prefix(5))...\(value.suffix(4))"
    }
}

extension CodexSubscriptionTier {
    /// Paid ChatGPT-style plans renew monthly; free/API/unknown should not invent future dates.
    fileprivate var projectsBillingCycleWhenStale: Bool {
        switch self {
        case .plus, .pro5x, .pro20x, .business, .team, .enterprise, .edu:
            return true
        case .free, .api, .unknown:
            return false
        }
    }
}

public struct RateWindow: Sendable, Equatable {
    public var usedPercent: Int
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(usedPercent: Int, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public struct NamedRateWindow: Sendable, Equatable {
    public var name: String
    public var window: RateWindow
}

public struct QuotaSnapshot: Sendable, Equatable {
    public var plan: String?
    public var primary: RateWindow
    public var secondary: RateWindow?
    public var additionalWindows: [NamedRateWindow]
    public var creditsBalance: Double?
    public var updatedAt: Date

    public var menuBarText: String {
        menuBarText(now: updatedAt)
    }

    public func menuBarText(now: Date, waitPrefix: String = "wait") -> String {
        guard let reset = primary.resetsAt else { return primary.usedPercent >= 100 ? waitPrefix : "\(primary.usedPercent)%" }
        let prefix = primary.usedPercent >= 100 ? "\(waitPrefix) " : ""
        return prefix + DurationFormatter.localized(reset.timeIntervalSince(now), language: .english, includeSeconds: false)
    }

    public func nextDueReset(after triggeredReset: Date?, now: Date) -> Date? {
        let resets = ([primary.resetsAt, secondary?.resetsAt] + additionalWindows.map { $0.window.resetsAt })
            .compactMap(\.self)
        let triggeredReset = triggeredReset ?? .distantPast
        return resets
            .filter { $0 > triggeredReset && now.timeIntervalSince($0) >= 1 }
            .sorted()
            .first
    }

    /// Best quota window to treat as the "billing/usage cycle" for API cost.
    /// Prefers the longest complete window (typically weekly secondary over 5-hour primary)
    /// so accounts that only expose weekly on `primary` still resolve.
    public func cycleAnchorWindow() -> RateWindow? {
        let candidates = ([secondary, primary] + additionalWindows.map(\.window))
            .compactMap { $0 }
            .filter { window in
                window.resetsAt != nil && (window.windowMinutes ?? 0) > 0
            }
        return candidates.max { lhs, rhs in
            (lhs.windowMinutes ?? 0) < (rhs.windowMinutes ?? 0)
        }
    }

    /// Full cycle interval and elapsed-so-far interval for API cost queries.
    public func cycleWindows(now: Date = Date()) -> (full: DateInterval, elapsed: DateInterval)? {
        guard let anchor = cycleAnchorWindow(),
              let reset = anchor.resetsAt,
              let minutes = anchor.windowMinutes,
              minutes > 0
        else { return nil }
        let start = reset.addingTimeInterval(-TimeInterval(minutes * 60))
        guard start < reset else { return nil }
        let full = DateInterval(start: start, end: reset)
        let elapsedEnd = min(max(now, start), reset)
        // Zero-length windows produce empty scans and false "unavailable" states.
        guard elapsedEnd > start else {
            return (full, DateInterval(start: start, end: min(start.addingTimeInterval(1), reset)))
        }
        return (full, DateInterval(start: start, end: elapsedEnd))
    }

    public static func decode(from data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        let response = try JSONDecoder().decode(QuotaResponse.self, from: data)
        return QuotaSnapshot(
            plan: response.planType,
            primary: response.rateLimit.primaryWindow.rateWindow,
            secondary: response.rateLimit.secondaryWindow?.rateWindow,
            additionalWindows: response.additionalRateLimits.compactMap(\.namedWindow),
            creditsBalance: response.credits?.balance,
            updatedAt: now)
    }
}

public struct ResetCredit: Sendable, Equatable {
    public var id: String?
    public var status: String
    public var createdAt: Date?
    public var expiresAt: Date?
    public var remainingSeconds: TimeInterval
}

public struct ResetCreditsSnapshot: Sendable, Equatable {
    public var availableCount: Int
    public var credits: [ResetCredit]
    public var updatedAt: Date

    public static func decode(from data: Data, now: Date = Date()) throws -> ResetCreditsSnapshot {
        let response = try JSONDecoder().decode(ResetCreditsResponse.self, from: data)
        let credits = response.credits.map { item in
            ResetCredit(
                id: item.id,
                status: item.status ?? "unknown",
                createdAt: item.createdAt,
                expiresAt: item.expiresAt,
                remainingSeconds: max(0, item.expiresAt?.timeIntervalSince(now) ?? 0))
        }
        return ResetCreditsSnapshot(
            availableCount: response.availableCount ?? credits.filter { $0.status == "available" }.count,
            credits: credits,
            updatedAt: now)
    }
}

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int

    public static let zero = TokenUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0)
}

public struct ModelCostBreakdown: Sendable, Equatable {
    public var model: String
    public var usage: TokenUsage
    public var estimatedUSD: Decimal
}

public struct UsageCostSummary: Sendable, Equatable {
    public var window: DateInterval
    public var totals: TokenUsage
    public var modelBreakdown: [ModelCostBreakdown]
    public var estimatedUSD: Decimal
    public var pricingVersion: String
    public var unknownModels: [String]
}

public struct SessionRepairReport: Sendable, Equatable {
    public var missingIndexIDs: [String]
    public var orphanIndexIDs: [String]
    public var duplicateIndexIDs: [String]
    public var staleTitleIDs: [String]
    public var backupPath: URL?
    public var plannedEntries: Int
}

extension Data {
    init?(base64URLEncoded value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - text.count % 4) % 4
        text += String(repeating: "=", count: padding)
        self.init(base64Encoded: text)
    }
}
