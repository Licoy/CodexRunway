import Foundation

public struct CodexProfileTokenUsage: Sendable, Equatable {
    public var dailyTokens: [String: Int]
    public var statsAsOf: String?
    public var generatedAt: Date?

    public init(
        dailyTokens: [String: Int],
        statsAsOf: String? = nil,
        generatedAt: Date? = nil)
    {
        self.dailyTokens = dailyTokens
        self.statsAsOf = statsAsOf
        self.generatedAt = generatedAt
    }

    public static func decode(from data: Data) throws -> Self {
        let response = try JSONDecoder().decode(ProfileResponse.self, from: data)
        if let statsError = response.metadata?.statsError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !statsError.isEmpty
        {
            throw invalid("Codex profile stats are unavailable")
        }
        guard let buckets = response.stats.dailyUsageBuckets else {
            throw invalid("Codex profile daily usage is missing")
        }

        var dailyTokens: [String: Int] = [:]
        dailyTokens.reserveCapacity(buckets.count)
        for bucket in buckets {
            guard isValidDayKey(bucket.startDate), bucket.tokens >= 0 else {
                throw invalid("Codex profile daily usage contains an invalid value")
            }
            guard dailyTokens.updateValue(bucket.tokens, forKey: bucket.startDate) == nil else {
                throw invalid("Codex profile daily usage contains a duplicate date")
            }
        }
        let statsAsOf = normalized(response.metadata?.statsAsOf)
        if let statsAsOf, !isValidDayKey(statsAsOf) {
            throw invalid("Codex profile stats date is invalid")
        }
        let generatedAtText = normalized(response.metadata?.generatedAt)
        let generatedAt = generatedAtText.flatMap(RunwayDates.parse)
        if generatedAtText != nil, generatedAt == nil {
            throw invalid("Codex profile generation timestamp is invalid")
        }
        return Self(
            dailyTokens: dailyTokens,
            statsAsOf: statsAsOf,
            generatedAt: generatedAt)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func isValidDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }

    private static func invalid(_ description: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: description))
    }
}

private struct ProfileResponse: Decodable {
    var stats: ProfileStats
    var metadata: ProfileMetadata?
}

private struct ProfileStats: Decodable {
    var dailyUsageBuckets: [ProfileDailyUsageBucket]?

    enum CodingKeys: String, CodingKey {
        case dailyUsageBuckets = "daily_usage_buckets"
    }
}

private struct ProfileMetadata: Decodable {
    var statsError: String?
    var statsAsOf: String?
    var generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case statsError = "stats_error"
        case statsAsOf = "stats_as_of"
        case generatedAt = "generated_at"
    }
}

private struct ProfileDailyUsageBucket: Decodable {
    var startDate: String
    var tokens: Int

    enum CodingKeys: String, CodingKey {
        case startDate = "start_date"
        case tokens
    }
}
