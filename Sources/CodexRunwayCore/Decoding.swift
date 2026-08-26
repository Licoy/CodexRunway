import Foundation

struct QuotaResponse: Decodable {
    var planType: String?
    var rateLimit: RateLimitResponse
    var credits: CreditResponse?
    var additionalRateLimits: [AdditionalRateLimitResponse]

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case additionalRateLimits = "additional_rate_limits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try container.decode(RateLimitResponse.self, forKey: .rateLimit)
        credits = try container.decodeIfPresent(CreditResponse.self, forKey: .credits)
        additionalRateLimits = (try? container.decodeIfPresent([AdditionalRateLimitResponse].self, forKey: .additionalRateLimits)) ?? []
    }
}

struct RateLimitResponse: Decodable {
    var primaryWindow: WindowResponse
    var secondaryWindow: WindowResponse?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct WindowResponse: Decodable {
    var usedPercent: Int
    var usedPercentExact: Double
    var resetAt: Int
    var limitWindowSeconds: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let exact = try container.decodeFlexibleDouble(.usedPercent)
        usedPercentExact = exact
        usedPercent = Int(exact.rounded())
        resetAt = try container.decode(Int.self, forKey: .resetAt)
        limitWindowSeconds = try container.decode(Int.self, forKey: .limitWindowSeconds)
    }

    var rateWindow: RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: limitWindowSeconds > 0 ? limitWindowSeconds / 60 : nil,
            resetsAt: resetAt > 0 ? Date(timeIntervalSince1970: TimeInterval(resetAt)) : nil,
            usedPercentExact: usedPercentExact)
    }
}

struct CreditResponse: Decodable {
    var balance: Double?

    enum CodingKeys: String, CodingKey {
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        balance = try? container.decodeIfPresent(Double.self, forKey: .balance)
        if balance == nil, let text = try? container.decodeIfPresent(String.self, forKey: .balance) {
            balance = Double(text)
        }
    }
}

struct AdditionalRateLimitResponse: Decodable {
    var limitName: String?
    var meteredFeature: String?
    var rateLimit: RateLimitResponse?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }

    var namedWindow: NamedRateWindow? {
        guard let window = rateLimit?.primaryWindow.rateWindow ?? rateLimit?.secondaryWindow?.rateWindow else { return nil }
        return NamedRateWindow(name: firstNonEmpty(limitName, meteredFeature) ?? "Codex extra limit", window: window)
    }
}

struct ResetCreditsResponse: Decodable {
    var availableCount: Int?
    var credits: [ResetCreditResponse]

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var values: [ResetCreditResponse] = []
            while !array.isAtEnd {
                values.append(try array.decode(ResetCreditResponse.self))
            }
            availableCount = nil
            credits = values
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try container.decodeIfPresent(Int.self, forKey: .availableCount)
        credits = (try? container.decodeIfPresent([ResetCreditResponse].self, forKey: .credits)) ?? []
    }
}

struct ResetCreditResponse: Decodable {
    var id: String?
    var status: String?
    var createdAt: Date?
    var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        createdAt = FlexibleDate.decode(container, key: .createdAt)
        expiresAt = FlexibleDate.decode(container, key: .expiresAt)
    }
}

enum FlexibleDate {
    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, key: K) -> Date? {
        if let seconds = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return RunwayDates.parse(text)
        }
        return nil
    }
}

func firstNonEmpty(_ values: String?...) -> String? {
    values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}

extension KeyedDecodingContainer {
    func decodeFlexibleDouble(_ key: Key) throws -> Double {
        if let value = try? decode(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }
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

enum RunwayDates {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
