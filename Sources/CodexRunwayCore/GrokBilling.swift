import Foundation

public enum GrokQuotaPeriodKind: String, Codable, Sendable, Equatable {
    case weekly
    case monthly
}

public struct GrokQuotaPeriod: Codable, Sendable, Equatable {
    public var kind: GrokQuotaPeriodKind
    public var startsAt: Date?
    public var resetsAt: Date?

    public init(kind: GrokQuotaPeriodKind, startsAt: Date?, resetsAt: Date?) {
        self.kind = kind
        self.startsAt = startsAt
        self.resetsAt = resetsAt
    }
}

public enum GrokBillingSource: String, Codable, Sendable, Equatable {
    case current
    case deprecated
    case legacyFlat
}

/// Product-level share of included credits (e.g. GrokBuild / GrokImagine / GrokChat).
/// `usagePercent` is the product's contribution to overall included usage.
public struct GrokProductUsage: Codable, Sendable, Equatable, Identifiable {
    public var id: String { product }
    public var product: String
    public var usagePercent: Double

    public init(product: String, usagePercent: Double) {
        self.product = product
        self.usagePercent = usagePercent
    }
}

public enum GrokBillingDecodingError: Error, Sendable, Equatable {
    case unknownStructure
    case invalidPercentage
    case invalidPeriodType(String)
    case invalidDate(String)
    case invalidPeriod
}

public struct GrokQuotaSnapshot: Codable, Sendable, Equatable {
    public var plan: String?
    public var includedUsagePercent: Double
    public var period: GrokQuotaPeriod?
    /// Included allowance budget in USD cents (`config.monthlyLimit`), when known.
    public var includedLimitCents: Int64?
    /// Included allowance used in USD cents (`config.used`), when known.
    public var includedUsedCents: Int64?
    public var prepaidBalanceCents: Int64?
    public var onDemandEnabled: Bool?
    public var onDemandUsedCents: Int64?
    public var onDemandLimitCents: Int64?
    /// Product breakdown from `config.productUsage` (CLI chat-proxy).
    public var productUsage: [GrokProductUsage]
    public var isUnifiedBillingUser: Bool?
    public var source: GrokBillingSource
    public var updatedAt: Date

    public init(
        plan: String?,
        includedUsagePercent: Double,
        period: GrokQuotaPeriod?,
        includedLimitCents: Int64? = nil,
        includedUsedCents: Int64? = nil,
        prepaidBalanceCents: Int64?,
        onDemandEnabled: Bool?,
        onDemandUsedCents: Int64?,
        onDemandLimitCents: Int64?,
        productUsage: [GrokProductUsage] = [],
        isUnifiedBillingUser: Bool? = nil,
        source: GrokBillingSource,
        updatedAt: Date)
    {
        self.plan = plan
        self.includedUsagePercent = includedUsagePercent
        self.period = period
        self.includedLimitCents = includedLimitCents
        self.includedUsedCents = includedUsedCents
        self.prepaidBalanceCents = prepaidBalanceCents
        self.onDemandEnabled = onDemandEnabled
        self.onDemandUsedCents = onDemandUsedCents
        self.onDemandLimitCents = onDemandLimitCents
        self.productUsage = productUsage
        self.isUnifiedBillingUser = isUnifiedBillingUser
        self.source = source
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case plan
        case includedUsagePercent
        case period
        case includedLimitCents
        case includedUsedCents
        case prepaidBalanceCents
        case onDemandEnabled
        case onDemandUsedCents
        case onDemandLimitCents
        case productUsage
        case isUnifiedBillingUser
        case source
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        includedUsagePercent = try container.decode(Double.self, forKey: .includedUsagePercent)
        period = try container.decodeIfPresent(GrokQuotaPeriod.self, forKey: .period)
        includedLimitCents = try container.decodeIfPresent(Int64.self, forKey: .includedLimitCents)
        includedUsedCents = try container.decodeIfPresent(Int64.self, forKey: .includedUsedCents)
        prepaidBalanceCents = try container.decodeIfPresent(Int64.self, forKey: .prepaidBalanceCents)
        onDemandEnabled = try container.decodeIfPresent(Bool.self, forKey: .onDemandEnabled)
        onDemandUsedCents = try container.decodeIfPresent(Int64.self, forKey: .onDemandUsedCents)
        onDemandLimitCents = try container.decodeIfPresent(Int64.self, forKey: .onDemandLimitCents)
        productUsage = try container.decodeIfPresent([GrokProductUsage].self, forKey: .productUsage) ?? []
        isUnifiedBillingUser = try container.decodeIfPresent(Bool.self, forKey: .isUnifiedBillingUser)
        source = try container.decode(GrokBillingSource.self, forKey: .source)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// Remaining included allowance in USD cents when both limit and used are known.
    public var includedRemainingCents: Int64? {
        guard let limit = includedLimitCents else { return nil }
        let used = max(0, includedUsedCents ?? 0)
        return max(0, limit - used)
    }

    /// Prefer `preferred` when non-empty; otherwise keep/normalize the existing plan.
    public func mergingPlan(_ preferred: String?, overwrite: Bool = false) -> Self {
        var copy = self
        if overwrite, let display = GrokSubscriptionTier.displayName(from: preferred) {
            copy.plan = display
            return copy
        }
        if let display = GrokSubscriptionTier.displayName(from: preferred),
           copy.plan == nil || copy.plan?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
        {
            copy.plan = display
            return copy
        }
        if let display = GrokSubscriptionTier.displayName(from: copy.plan) {
            copy.plan = display
        }
        return copy
    }

    public func mergingMoneyAllowance(limitCents: Int64?, usedCents: Int64?) -> Self {
        var copy = self
        if copy.includedLimitCents == nil { copy.includedLimitCents = limitCents }
        if copy.includedUsedCents == nil { copy.includedUsedCents = usedCents }
        return copy
    }


    public static func decodeBillingResponse(from data: Data, now: Date = Date()) throws -> Self {
        let response: BillingResponse
        do {
            response = try JSONDecoder().decode(BillingResponse.self, from: data)
        } catch is DecodingError {
            throw GrokBillingDecodingError.unknownStructure
        }
        if let config = response.config {
            do {
                return try snapshot(from: config, response: response, now: now)
            } catch GrokBillingDecodingError.unknownStructure {
                // Older CLIs may include an empty wrapper alongside the legacy flat fields.
            }
        }
        return try legacySnapshot(from: response, now: now)
    }

    private static func snapshot(
        from config: BillingConfig,
        response: BillingResponse,
        now: Date) throws -> Self
    {
        let percent: Double
        let period: GrokQuotaPeriod?
        let source: GrokBillingSource
        if let currentPercent = config.creditUsagePercent {
            percent = currentPercent
            // Period is best-effort: unknown types / bad dates must not discard usage %.
            period = config.currentPeriod?.bestEffortQuotaPeriod()
            source = .current
        } else if let periodFromCurrent = config.currentPeriod?.bestEffortQuotaPeriod() {
            // After a weekly/monthly credits reset the API often returns the new
            // `currentPeriod` but omits `creditUsagePercent` (and productUsage)
            // until the first billable request. Treat that as 0% used — do not
            // fall through to monthly USD cents (a different window).
            percent = 0
            period = periodFromCurrent
            source = .current
        } else if let limit = config.monthlyLimit?.val,
                  limit > 0,
                  let used = config.used?.val
        {
            percent = Double(used) / Double(limit) * 100
            period = makeBestEffortQuotaPeriod(
                kind: .monthly,
                start: config.billingPeriodStart,
                end: config.billingPeriodEnd)
            source = .deprecated
        } else {
            throw GrokBillingDecodingError.unknownStructure
        }
        guard percent.isFinite else {
            throw GrokBillingDecodingError.invalidPercentage
        }
        return Self(
            plan: GrokSubscriptionTier.displayName(from: response.subscriptionTier),
            includedUsagePercent: percent,
            period: period,
            includedLimitCents: config.monthlyLimit?.val,
            includedUsedCents: config.used?.val,
            prepaidBalanceCents: config.prepaidBalance?.val,
            onDemandEnabled: response.onDemandEnabled,
            onDemandUsedCents: config.onDemandUsed?.val,
            onDemandLimitCents: config.onDemandCap?.val,
            productUsage: config.decodedProductUsage(),
            isUnifiedBillingUser: config.isUnifiedBillingUser,
            source: source,
            updatedAt: now)
    }

    private static func legacySnapshot(from response: BillingResponse, now: Date) throws -> Self {
        guard let limit = response.monthlyLimit?.val,
              limit > 0,
              let used = response.usage?.totalUsed?.val ?? response.usage?.includedUsed?.val
        else {
            throw GrokBillingDecodingError.unknownStructure
        }
        let percent = Double(used) / Double(limit) * 100
        guard percent.isFinite else {
            throw GrokBillingDecodingError.invalidPercentage
        }
        return Self(
            plan: GrokSubscriptionTier.displayName(from: response.subscriptionTier),
            includedUsagePercent: percent,
            period: makeBestEffortQuotaPeriod(
                kind: .monthly,
                start: response.billingCycle?.billingPeriodStart,
                end: response.billingCycle?.billingPeriodEnd),
            includedLimitCents: limit,
            includedUsedCents: used,
            prepaidBalanceCents: nil,
            onDemandEnabled: response.onDemandEnabled,
            onDemandUsedCents: response.usage?.onDemandUsed?.val,
            onDemandLimitCents: response.onDemandCap?.val,
            productUsage: [],
            isUnifiedBillingUser: nil,
            source: .legacyFlat,
            updatedAt: now)
    }

    /// Extract USD allowance fields from a default / `format=cents` billing payload.
    ///
    /// `format=credits` often omits `monthlyLimit`/`used`; the cents shape carries them.
    public static func decodeMoneyAllowance(from data: Data) throws -> (limitCents: Int64?, usedCents: Int64?) {
        let response: BillingResponse
        do {
            response = try JSONDecoder().decode(BillingResponse.self, from: data)
        } catch is DecodingError {
            throw GrokBillingDecodingError.unknownStructure
        }
        if let config = response.config {
            let limit = config.monthlyLimit?.val
            let used = config.used?.val
            if limit != nil || used != nil {
                return (limit, used)
            }
        }
        let limit = response.monthlyLimit?.val
        let used = response.usage?.totalUsed?.val ?? response.usage?.includedUsed?.val
        if limit != nil || used != nil {
            return (limit, used)
        }
        throw GrokBillingDecodingError.unknownStructure
    }

    /// Extract `subscription_tier_display` (or related keys) from `/v1/settings`.
    public static func decodeSettingsPlan(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let candidates = [
            object["subscription_tier_display"],
            object["subscriptionTierDisplay"],
            object["subscription_tier"],
            object["subscriptionTier"],
        ]
        for candidate in candidates {
            if let value = candidate as? String,
               let display = GrokSubscriptionTier.displayName(from: value)
            {
                return display
            }
        }
        return nil
    }
}

private struct BillingResponse: Decodable {
    var config: BillingConfig?
    var onDemandEnabled: Bool?
    var subscriptionTier: String?
    var billingCycle: LegacyBillingCycle?
    var monthlyLimit: Cent?
    var onDemandCap: Cent?
    var usage: LegacyBillingUsage?

    enum CodingKeys: String, CodingKey {
        case config
        case onDemandEnabled
        case onDemandEnabledSnake = "on_demand_enabled"
        case subscriptionTier
        case subscriptionTierSnake = "subscription_tier"
        case billingCycle
        case monthlyLimit
        case onDemandCap
        case usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Optional branches are best-effort so one nested type mismatch cannot
        // discard an otherwise usable credits / cents payload.
        config = try? container.decodeIfPresent(BillingConfig.self, forKey: .config)
        onDemandEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .onDemandEnabled))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .onDemandEnabledSnake))
            ?? nil
        subscriptionTier = (try? container.decodeIfPresent(String.self, forKey: .subscriptionTier))
            ?? (try? container.decodeIfPresent(String.self, forKey: .subscriptionTierSnake))
            ?? nil
        billingCycle = try? container.decodeIfPresent(LegacyBillingCycle.self, forKey: .billingCycle)
        monthlyLimit = try? container.decodeIfPresent(Cent.self, forKey: .monthlyLimit)
        onDemandCap = try? container.decodeIfPresent(Cent.self, forKey: .onDemandCap)
        usage = try? container.decodeIfPresent(LegacyBillingUsage.self, forKey: .usage)
    }
}

private struct BillingConfig: Decodable {
    var creditUsagePercent: Double?
    var currentPeriod: UsagePeriod?
    var onDemandCap: Cent?
    var onDemandUsed: Cent?
    var prepaidBalance: Cent?
    var monthlyLimit: Cent?
    var used: Cent?
    var billingPeriodStart: String?
    var billingPeriodEnd: String?
    var productUsage: [ProductUsageEntry]?
    var isUnifiedBillingUser: Bool?

    enum CodingKeys: String, CodingKey {
        case creditUsagePercent
        case currentPeriod
        case onDemandCap
        case onDemandUsed
        case prepaidBalance
        case monthlyLimit
        case used
        case billingPeriodStart
        case billingPeriodEnd
        case productUsage
        case isUnifiedBillingUser
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        creditUsagePercent = Self.decodeFlexibleDouble(from: container, forKey: .creditUsagePercent)
        currentPeriod = try? container.decodeIfPresent(UsagePeriod.self, forKey: .currentPeriod)
        onDemandCap = try? container.decodeIfPresent(Cent.self, forKey: .onDemandCap)
        onDemandUsed = try? container.decodeIfPresent(Cent.self, forKey: .onDemandUsed)
        prepaidBalance = try? container.decodeIfPresent(Cent.self, forKey: .prepaidBalance)
        monthlyLimit = try? container.decodeIfPresent(Cent.self, forKey: .monthlyLimit)
        used = try? container.decodeIfPresent(Cent.self, forKey: .used)
        billingPeriodStart = try? container.decodeIfPresent(String.self, forKey: .billingPeriodStart)
        billingPeriodEnd = try? container.decodeIfPresent(String.self, forKey: .billingPeriodEnd)
        // productUsage may arrive as an array of objects (current) or an unexpected shape.
        productUsage = try? container.decodeIfPresent([ProductUsageEntry].self, forKey: .productUsage)
        isUnifiedBillingUser = try? container.decodeIfPresent(Bool.self, forKey: .isUnifiedBillingUser)
    }

    private static func decodeFlexibleDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return Double(value)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key),
           let value = Double(text)
        {
            return value
        }
        return nil
    }

    /// Best-effort product breakdown; skips bad rows instead of failing the snapshot.
    func decodedProductUsage() -> [GrokProductUsage] {
        guard let productUsage else { return [] }
        var result: [GrokProductUsage] = []
        result.reserveCapacity(productUsage.count)
        for entry in productUsage {
            let name = entry.product?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { continue }
            let percent = entry.usagePercent ?? 0
            guard percent.isFinite else { continue }
            result.append(GrokProductUsage(product: name, usagePercent: percent))
        }
        return result.sorted {
            if $0.usagePercent != $1.usagePercent {
                return $0.usagePercent > $1.usagePercent
            }
            return $0.product.localizedCaseInsensitiveCompare($1.product) == .orderedAscending
        }
    }
}

private struct ProductUsageEntry: Decodable {
    var product: String?
    var usagePercent: Double?

    enum CodingKeys: String, CodingKey {
        case product
        case usagePercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        product = try? container.decodeIfPresent(String.self, forKey: .product)
        if let value = try? container.decodeIfPresent(Double.self, forKey: .usagePercent) {
            usagePercent = value
        } else if let value = try? container.decodeIfPresent(Int64.self, forKey: .usagePercent) {
            usagePercent = Double(value)
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .usagePercent),
                  let value = Double(text)
        {
            usagePercent = value
        } else {
            usagePercent = nil
        }
    }
}

private struct Cent: Decodable {
    var val: Int64

    enum CodingKeys: CodingKey {
        case val
    }

    init(from decoder: Decoder) throws {
        // Bare number: 15000
        if let single = try? decoder.singleValueContainer() {
            if let intVal = try? single.decode(Int64.self) {
                val = intVal
                return
            }
            if let doubleVal = try? single.decode(Double.self), doubleVal.isFinite {
                val = Int64(doubleVal.rounded())
                return
            }
            if let text = try? single.decode(String.self), let parsed = Self.parseInt64(text) {
                val = parsed
                return
            }
        }

        // Proto-style object: {"val": 15000}
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intVal = try? container.decode(Int64.self, forKey: .val) {
            val = intVal
            return
        }
        if let doubleVal = try? container.decode(Double.self, forKey: .val), doubleVal.isFinite {
            val = Int64(doubleVal.rounded())
            return
        }
        if let text = try? container.decode(String.self, forKey: .val),
           let parsed = Self.parseInt64(text)
        {
            val = parsed
            return
        }
        // Missing or empty object defaults to proto3 zero.
        val = 0
    }

    private static func parseInt64(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int64(trimmed) { return value }
        if let double = Double(trimmed), double.isFinite {
            return Int64(double.rounded())
        }
        return nil
    }
}

private struct LegacyBillingCycle: Decodable {
    var billingPeriodStart: String?
    var billingPeriodEnd: String?
}

private struct LegacyBillingUsage: Decodable {
    var includedUsed: Cent?
    var onDemandUsed: Cent?
    var totalUsed: Cent?
}

private struct UsagePeriod: Decodable {
    var type: String?
    var start: String?
    var end: String?

    /// Best-effort period decode. Unknown types or unparseable dates yield `nil`
    /// so included usage percent can still surface.
    func bestEffortQuotaPeriod() -> GrokQuotaPeriod? {
        let kind: GrokQuotaPeriodKind
        switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY":
            kind = .weekly
        case "USAGE_PERIOD_TYPE_MONTHLY":
            kind = .monthly
        default:
            return nil
        }
        return makeBestEffortQuotaPeriod(kind: kind, start: start, end: end)
    }
}

private func makeBestEffortQuotaPeriod(
    kind: GrokQuotaPeriodKind,
    start: String?,
    end: String?) -> GrokQuotaPeriod?
{
    guard start != nil || end != nil else {
        return GrokQuotaPeriod(kind: kind, startsAt: nil, resetsAt: nil)
    }
    if let start, RunwayDates.parse(start) == nil { return nil }
    if let end, RunwayDates.parse(end) == nil { return nil }
    let startsAt = start.flatMap(RunwayDates.parse)
    let resetsAt = end.flatMap(RunwayDates.parse)
    if let startsAt, let resetsAt, resetsAt <= startsAt {
        return nil
    }
    return GrokQuotaPeriod(kind: kind, startsAt: startsAt, resetsAt: resetsAt)
}
