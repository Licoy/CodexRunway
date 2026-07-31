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
    public var prepaidBalanceCents: Int64?
    public var onDemandEnabled: Bool?
    public var onDemandUsedCents: Int64?
    public var onDemandLimitCents: Int64?
    public var source: GrokBillingSource
    public var updatedAt: Date

    public init(
        plan: String?,
        includedUsagePercent: Double,
        period: GrokQuotaPeriod?,
        prepaidBalanceCents: Int64?,
        onDemandEnabled: Bool?,
        onDemandUsedCents: Int64?,
        onDemandLimitCents: Int64?,
        source: GrokBillingSource,
        updatedAt: Date)
    {
        self.plan = plan
        self.includedUsagePercent = includedUsagePercent
        self.period = period
        self.prepaidBalanceCents = prepaidBalanceCents
        self.onDemandEnabled = onDemandEnabled
        self.onDemandUsedCents = onDemandUsedCents
        self.onDemandLimitCents = onDemandLimitCents
        self.source = source
        self.updatedAt = updatedAt
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
            period = try config.currentPeriod?.quotaPeriod()
            source = .current
        } else if let limit = config.monthlyLimit?.val,
                  limit > 0,
                  let used = config.used?.val
        {
            percent = Double(used) / Double(limit) * 100
            period = try quotaPeriod(
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
            plan: response.subscriptionTier,
            includedUsagePercent: percent,
            period: period,
            prepaidBalanceCents: config.prepaidBalance?.val,
            onDemandEnabled: response.onDemandEnabled,
            onDemandUsedCents: config.onDemandUsed?.val,
            onDemandLimitCents: config.onDemandCap?.val,
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
            plan: response.subscriptionTier,
            includedUsagePercent: percent,
            period: try quotaPeriod(
                kind: .monthly,
                start: response.billingCycle?.billingPeriodStart,
                end: response.billingCycle?.billingPeriodEnd),
            prepaidBalanceCents: nil,
            onDemandEnabled: response.onDemandEnabled,
            onDemandUsedCents: response.usage?.onDemandUsed?.val,
            onDemandLimitCents: response.onDemandCap?.val,
            source: .legacyFlat,
            updatedAt: now)
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
        config = try container.decodeIfPresent(BillingConfig.self, forKey: .config)
        onDemandEnabled = try container.decodeIfPresent(Bool.self, forKey: .onDemandEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .onDemandEnabledSnake)
        subscriptionTier = try container.decodeIfPresent(String.self, forKey: .subscriptionTier)
            ?? container.decodeIfPresent(String.self, forKey: .subscriptionTierSnake)
        billingCycle = try container.decodeIfPresent(LegacyBillingCycle.self, forKey: .billingCycle)
        monthlyLimit = try container.decodeIfPresent(Cent.self, forKey: .monthlyLimit)
        onDemandCap = try container.decodeIfPresent(Cent.self, forKey: .onDemandCap)
        usage = try container.decodeIfPresent(LegacyBillingUsage.self, forKey: .usage)
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
}

private struct Cent: Decodable {
    var val: Int64

    enum CodingKeys: CodingKey {
        case val
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        val = try container.decodeIfPresent(Int64.self, forKey: .val) ?? 0
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

    func quotaPeriod() throws -> GrokQuotaPeriod {
        let kind: GrokQuotaPeriodKind
        switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY":
            kind = .weekly
        case "USAGE_PERIOD_TYPE_MONTHLY":
            kind = .monthly
        case let value?:
            throw GrokBillingDecodingError.invalidPeriodType(value)
        case nil:
            throw GrokBillingDecodingError.invalidPeriodType("missing")
        }
        let startsAt = try start.map(parseDate)
        let resetsAt = try end.map(parseDate)
        if let startsAt, let resetsAt, resetsAt <= startsAt {
            throw GrokBillingDecodingError.invalidPeriod
        }
        return GrokQuotaPeriod(kind: kind, startsAt: startsAt, resetsAt: resetsAt)
    }
}

private func parseDate(_ value: String) throws -> Date {
    guard let date = RunwayDates.parse(value) else {
        throw GrokBillingDecodingError.invalidDate(value)
    }
    return date
}

private func quotaPeriod(
    kind: GrokQuotaPeriodKind,
    start: String?,
    end: String?) throws -> GrokQuotaPeriod?
{
    guard start != nil || end != nil else { return nil }
    let startsAt = try start.map(parseDate)
    let resetsAt = try end.map(parseDate)
    if let startsAt, let resetsAt, resetsAt <= startsAt {
        throw GrokBillingDecodingError.invalidPeriod
    }
    return GrokQuotaPeriod(kind: kind, startsAt: startsAt, resetsAt: resetsAt)
}
