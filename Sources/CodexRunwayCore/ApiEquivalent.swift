import Foundation

public enum ApiEquivalentSource: String, Codable, Sendable, Equatable {
    case localSessions
    case onlineAnalytics
    case unavailable
}

public enum ApiEquivalentConfidence: String, Codable, Sendable, Equatable {
    case priced
    case tokensOnly
    case unavailable
}

public struct ApiEquivalentTotals: Codable, Sendable, Equatable {
    public var totalTokens: Int
    public var uncachedInputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var turns: Int
    public var threads: Int

    public static let zero = ApiEquivalentTotals(
        totalTokens: 0,
        uncachedInputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        turns: 0,
        threads: 0)

    public var hasTokenParts: Bool {
        uncachedInputTokens > 0 || cachedInputTokens > 0 || outputTokens > 0
    }
}

public struct ApiEquivalentDailyRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String { date }
    public var date: String
    public var totals: ApiEquivalentTotals
    public var estimatedUSD: Decimal?
    public var rawCredits: Double
    /// Nil for local or legacy data whose credit reporting status is unknown.
    public var creditsReported: Bool? = nil
    /// Nil for local or legacy data whose daily totals reporting status is unknown.
    public var totalsReported: Bool? = nil
}

public struct ApiEquivalentBreakdownRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var totals: ApiEquivalentTotals
    public var estimatedUSD: Decimal?
    public var rawCredits: Double
}

public struct ApiEquivalentSummary: Codable, Sendable, Equatable {
    public var source: ApiEquivalentSource
    public var confidence: ApiEquivalentConfidence
    public var window: DateInterval
    public var estimatedUSD: Decimal?
    public var totals: ApiEquivalentTotals
    public var dailyRows: [ApiEquivalentDailyRow]
    public var modelRows: [ApiEquivalentBreakdownRow]
    public var projectRows: [ApiEquivalentBreakdownRow]
    public var clientRows: [ApiEquivalentBreakdownRow]
    public var rawCredits: Double
    public var warnings: [String]
    public var pricingVersion: String
    public var calculatedAt: Date

    public var isDisplayableCost: Bool {
        confidence != .unavailable && totals.totalTokens > 0
    }

    public init(
        source: ApiEquivalentSource,
        confidence: ApiEquivalentConfidence,
        window: DateInterval,
        estimatedUSD: Decimal?,
        totals: ApiEquivalentTotals,
        dailyRows: [ApiEquivalentDailyRow],
        modelRows: [ApiEquivalentBreakdownRow],
        projectRows: [ApiEquivalentBreakdownRow] = [],
        clientRows: [ApiEquivalentBreakdownRow],
        rawCredits: Double,
        warnings: [String],
        pricingVersion: String,
        calculatedAt: Date)
    {
        self.source = source
        self.confidence = confidence
        self.window = window
        self.estimatedUSD = estimatedUSD
        self.totals = totals
        self.dailyRows = dailyRows
        self.modelRows = modelRows
        self.projectRows = projectRows
        self.clientRows = clientRows
        self.rawCredits = rawCredits
        self.warnings = warnings
        self.pricingVersion = pricingVersion
        self.calculatedAt = calculatedAt
    }

    enum CodingKeys: String, CodingKey {
        case source
        case confidence
        case window
        case estimatedUSD
        case totals
        case dailyRows
        case modelRows
        case projectRows
        case clientRows
        case rawCredits
        case warnings
        case pricingVersion
        case calculatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(ApiEquivalentSource.self, forKey: .source)
        confidence = try container.decode(ApiEquivalentConfidence.self, forKey: .confidence)
        window = try container.decode(DateInterval.self, forKey: .window)
        estimatedUSD = try container.decodeIfPresent(Decimal.self, forKey: .estimatedUSD)
        totals = try container.decode(ApiEquivalentTotals.self, forKey: .totals)
        dailyRows = try container.decode([ApiEquivalentDailyRow].self, forKey: .dailyRows)
        modelRows = try container.decode([ApiEquivalentBreakdownRow].self, forKey: .modelRows)
        projectRows = try container.decodeIfPresent([ApiEquivalentBreakdownRow].self, forKey: .projectRows) ?? []
        clientRows = try container.decode([ApiEquivalentBreakdownRow].self, forKey: .clientRows)
        rawCredits = try container.decode(Double.self, forKey: .rawCredits)
        warnings = try container.decode([String].self, forKey: .warnings)
        pricingVersion = try container.decode(String.self, forKey: .pricingVersion)
        calculatedAt = try container.decode(Date.self, forKey: .calculatedAt)
    }

    public static func unavailable(window: DateInterval, warning: String? = nil, calculatedAt: Date = Date()) -> ApiEquivalentSummary {
        ApiEquivalentSummary(
            source: .unavailable,
            confidence: .unavailable,
            window: window,
            estimatedUSD: nil,
            totals: .zero,
            dailyRows: [],
            modelRows: [],
            projectRows: [],
            clientRows: [],
            rawCredits: 0,
            warnings: warning.map { [$0] } ?? [],
            pricingVersion: PricingTable.version,
            calculatedAt: calculatedAt)
    }

    public static func decodeAnalytics(
        from data: Data,
        window: DateInterval,
        calculatedAt: Date = Date(),
        startDate: String? = nil,
        endDate: String? = nil
    ) throws -> ApiEquivalentSummary {
        let response = try JSONDecoder().decode(ApiAnalyticsResponse.self, from: data)
        // Prefer the same inclusive day strings used for the HTTP request. Deriving days
        // from window timestamps in UTC dropped local-calendar ranges (e.g. Asia/Shanghai).
        let start = startDate ?? apiDay(window.start)
        let end = endDate ?? apiDay(window.end)
        let lower = min(start, end)
        let upper = max(start, end)
        let items = response.data
            .filter { $0.date >= lower && $0.date <= upper }
            .sorted { $0.date < $1.date }
        let rows = try items.map { item -> ApiEquivalentDailyRow in
            let totals = try item.totals?.checkedAPITotals() ?? .zero
            return ApiEquivalentDailyRow(
                date: item.date,
                totals: totals,
                estimatedUSD: totals.hasTokenParts ? PricingTable.equivalentCost(totals: totals) : nil,
                rawCredits: item.totals?.credits ?? 0,
                creditsReported: item.totals?.creditsReported ?? false,
                totalsReported: item.totals != nil)
        }
        let totals = try ApiEquivalentTotals.sum(rows.map(\.totals))
        let estimated = rows.compactMap(\.estimatedUSD).reduce(Decimal(0), +)
        let hasUnpricedUsage = rows.contains {
            $0.totalsReported != true || ($0.totals.totalTokens > 0 && $0.estimatedUSD == nil)
        }
        let hasCompleteCost = totals.hasTokenParts && !hasUnpricedUsage
        let rawCredits = try checkedFiniteSum(rows.map(\.rawCredits), field: "analytics credits")
        return ApiEquivalentSummary(
            source: .onlineAnalytics,
            confidence: hasCompleteCost ? .priced : (totals.totalTokens > 0 ? .tokensOnly : .unavailable),
            window: window,
            estimatedUSD: hasCompleteCost ? estimated : nil,
            totals: totals,
            dailyRows: rows,
            modelRows: try breakdown(items.flatMap(\.models)),
            projectRows: [],
            clientRows: try breakdown(items.flatMap(\.clients)),
            rawCredits: rawCredits,
            warnings: hasCompleteCost ? [] : ["analytics-token-parts-missing"],
            pricingVersion: PricingTable.version,
            calculatedAt: calculatedAt)
    }

    static func apiDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func breakdown(
        _ items: [ApiAnalyticsBreakdownItem]
    ) throws -> [ApiEquivalentBreakdownRow] {
        let grouped = Dictionary(grouping: items) { $0.displayName }
        return try grouped.map { name, values in
            let totals = try ApiEquivalentTotals.sum(values.map { try $0.checkedAPITotals() })
            let rawCredits = try checkedFiniteSum(
                values.map(\.credits),
                field: "analytics breakdown credits")
            return ApiEquivalentBreakdownRow(
                name: name,
                totals: totals,
                estimatedUSD: totals.hasTokenParts ? PricingTable.equivalentCost(totals: totals) : nil,
                rawCredits: rawCredits)
        }
        .filter { $0.totals.totalTokens > 0 || $0.totals.turns > 0 || $0.rawCredits > 0 }
        .sorted { $0.totals.totalTokens > $1.totals.totalTokens }
    }
}

private struct ApiAnalyticsResponse: Decodable {
    var data: [ApiAnalyticsDay]
}

private struct ApiAnalyticsDay: Decodable {
    var date: String
    var totals: ApiAnalyticsTotals?
    var models: [ApiAnalyticsBreakdownItem]
    var clients: [ApiAnalyticsBreakdownItem]

    enum CodingKeys: String, CodingKey {
        case date
        case totals
        case models
        case clients
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        totals = try container.decodeIfPresent(ApiAnalyticsTotals.self, forKey: .totals)
        models = try container.decodeIfPresent(
            [ApiAnalyticsBreakdownItem].self,
            forKey: .models) ?? []
        clients = try container.decodeIfPresent(
            [ApiAnalyticsBreakdownItem].self,
            forKey: .clients) ?? []
    }
}

private struct ApiAnalyticsBreakdownItem: Decodable {
    var clientID: String?
    var model: String?
    var name: String?
    var id: String?
    var totals: ApiAnalyticsTotals

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case model
        case name
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try? container.decodeIfPresent(String.self, forKey: .clientID)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        totals = try ApiAnalyticsTotals(from: decoder)
    }

    var displayName: String {
        firstNonEmpty(clientID, model, name, id) ?? "UNKNOWN"
    }

    func checkedAPITotals() throws -> ApiEquivalentTotals { try totals.checkedAPITotals() }
    var credits: Double { totals.credits }
}

private struct ApiAnalyticsTotals: Decodable {
    var credits: Double
    var creditsReported: Bool
    var turns: Int
    var threads: Int
    var textTotalTokens: Int
    var cachedTextInputTokens: Int
    var uncachedTextInputTokens: Int
    var textOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case credits
        case turns
        case threads
        case textTotalTokens = "text_total_tokens"
        case cachedTextInputTokens = "cached_text_input_tokens"
        case uncachedTextInputTokens = "uncached_text_input_tokens"
        case textOutputTokens = "text_output_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credits = try container.flexibleDouble(.credits)
        guard credits >= 0 else { throw UsageCostArithmeticError.invalidValue(field: "analytics credits") }
        creditsReported = try container.contains(.credits) && !container.decodeNil(forKey: .credits)
        turns = try container.flexibleInt(.turns)
        threads = try container.flexibleInt(.threads)
        textTotalTokens = try container.flexibleInt(.textTotalTokens)
        cachedTextInputTokens = try container.flexibleInt(.cachedTextInputTokens)
        uncachedTextInputTokens = try container.flexibleInt(.uncachedTextInputTokens)
        textOutputTokens = try container.flexibleInt(.textOutputTokens)
    }

    func checkedAPITotals() throws -> ApiEquivalentTotals {
        guard turns >= 0,
              threads >= 0,
              textTotalTokens >= 0,
              cachedTextInputTokens >= 0,
              uncachedTextInputTokens >= 0,
              textOutputTokens >= 0
        else { throw UsageCostArithmeticError.invalidValue(field: "analytics token usage") }
        let input = try checkedAdd(
            uncachedTextInputTokens,
            cachedTextInputTokens,
            field: "analytics input tokens")
        let parts = try checkedAdd(input, textOutputTokens, field: "analytics total tokens")
        return ApiEquivalentTotals(
            totalTokens: textTotalTokens > 0 ? textTotalTokens : parts,
            uncachedInputTokens: uncachedTextInputTokens,
            cachedInputTokens: cachedTextInputTokens,
            outputTokens: textOutputTokens,
            turns: turns,
            threads: threads)
    }
}

private extension KeyedDecodingContainer where Key == ApiAnalyticsTotals.CodingKeys {
    func flexibleInt(_ key: Key) throws -> Int {
        guard contains(key), try !decodeNil(forKey: key) else { return 0 }
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key),
           value.isFinite,
           let exact = Int(exactly: value)
        {
            return exact
        }
        if let value = try? decode(String.self, forKey: key),
           let exact = Int(value)
        {
            return exact
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected an exact finite integer")
    }

    func flexibleDouble(_ key: Key) throws -> Double {
        guard contains(key), try !decodeNil(forKey: key) else { return 0 }
        if let value = try? decode(Double.self, forKey: key), value.isFinite { return value }
        if let value = try? decode(Int.self, forKey: key) { return Double(value) }
        if let text = try? decode(String.self, forKey: key),
           let value = Double(text),
           value.isFinite
        {
            return value
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected a finite number")
    }
}
