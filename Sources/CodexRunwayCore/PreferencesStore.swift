import Foundation

public enum LanguagePreference: String, CaseIterable, Codable, Sendable {
    case system
    case english
    case simplifiedChinese
}

public enum ResolvedLanguage: String, Sendable, Equatable {
    case english
    case simplifiedChinese
}

public enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark
}

public enum StatusBarDisplayStyle: String, CaseIterable, Codable, Sendable {
    case countdown
    case battery
    case meters
    case rings
}

public enum StatusBarMetersDetailStyle: String, CaseIterable, Codable, Sendable {
    case remainingPercent
    case resetTime
    case both
}

public enum StatusBarBatteryScope: String, CaseIterable, Codable, Sendable {
    case fiveHour
    case weekly
    case both
}

public enum StatusBarBatteryDetailStyle: String, CaseIterable, Codable, Sendable {
    case countdown
    case remainingPercent
}

public enum ApiCostSummaryRange: String, CaseIterable, Codable, Sendable {
    case today
    case current
    case previous
    case thisMonth
}

public struct RunwayPreferences: Codable, Sendable, Equatable {
    public var language: LanguagePreference
    public var appearance: AppearancePreference
    public var statusBarDisplayStyle: StatusBarDisplayStyle
    public var statusBarMetersDetailStyle: StatusBarMetersDetailStyle
    public var statusBarBatteryScope: StatusBarBatteryScope
    public var statusBarBatteryDetailStyle: StatusBarBatteryDetailStyle
    public var refreshIntervalSeconds: Int
    public var apiCostSummaryRange: ApiCostSummaryRange
    public var showsCostSummary: Bool
    public var showsRecentSessions: Bool
    public var showsSessionRepairSummary: Bool
    public var showsRateLimitResetToday: Bool
    public var showsTokenUsageHeatmap: Bool
    public var rateLimitResetTodayRefreshIntervalSeconds: Int
    public var automaticallyChecksForUpdates: Bool
    public var quotaAlertsEnabled: Bool
    public var resetCreditAlertsEnabled: Bool
    public var exportsStatusJSON: Bool

    public static let rateLimitResetTodayRefreshIntervalOptions: [Int] = [900, 1_800, 3_600, 7_200, 21_600]
    public static let defaultRateLimitResetTodayRefreshIntervalSeconds = 3_600

    public init(
        language: LanguagePreference = .system,
        appearance: AppearancePreference = .system,
        statusBarDisplayStyle: StatusBarDisplayStyle = .meters,
        statusBarMetersDetailStyle: StatusBarMetersDetailStyle = .remainingPercent,
        statusBarBatteryScope: StatusBarBatteryScope = .fiveHour,
        statusBarBatteryDetailStyle: StatusBarBatteryDetailStyle = .countdown,
        refreshIntervalSeconds: Int = 300,
        apiCostSummaryRange: ApiCostSummaryRange = .today,
        showsCostSummary: Bool = true,
        showsRecentSessions: Bool = false,
        showsSessionRepairSummary: Bool = true,
        showsRateLimitResetToday: Bool = true,
        showsTokenUsageHeatmap: Bool = true,
        rateLimitResetTodayRefreshIntervalSeconds: Int = RunwayPreferences.defaultRateLimitResetTodayRefreshIntervalSeconds,
        automaticallyChecksForUpdates: Bool = true,
        quotaAlertsEnabled: Bool = false,
        resetCreditAlertsEnabled: Bool = false,
        exportsStatusJSON: Bool = false)
    {
        self.language = language
        self.appearance = appearance
        self.statusBarDisplayStyle = statusBarDisplayStyle
        self.statusBarMetersDetailStyle = statusBarMetersDetailStyle
        self.statusBarBatteryScope = statusBarBatteryScope
        self.statusBarBatteryDetailStyle = statusBarBatteryDetailStyle
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.apiCostSummaryRange = apiCostSummaryRange
        self.showsCostSummary = showsCostSummary
        self.showsRecentSessions = showsRecentSessions
        self.showsSessionRepairSummary = showsSessionRepairSummary
        self.showsRateLimitResetToday = showsRateLimitResetToday
        self.showsTokenUsageHeatmap = showsTokenUsageHeatmap
        self.rateLimitResetTodayRefreshIntervalSeconds = Self.clampRateLimitResetTodayRefreshInterval(
            rateLimitResetTodayRefreshIntervalSeconds)
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.quotaAlertsEnabled = quotaAlertsEnabled
        self.resetCreditAlertsEnabled = resetCreditAlertsEnabled
        self.exportsStatusJSON = exportsStatusJSON
    }

    public static func clampRateLimitResetTodayRefreshInterval(_ seconds: Int) -> Int {
        max(900, min(21_600, seconds))
    }

    enum CodingKeys: String, CodingKey {
        case language
        case appearance
        case statusBarDisplayStyle
        case statusBarMetersDetailStyle
        case statusBarBatteryScope
        case statusBarBatteryDetailStyle
        case refreshIntervalSeconds
        case apiCostSummaryRange
        case showsCostSummary
        case showsRecentSessions
        case showsSessionRepairSummary
        case showsRateLimitResetToday
        case showsTokenUsageHeatmap
        case rateLimitResetTodayRefreshIntervalSeconds
        case automaticallyChecksForUpdates
        case quotaAlertsEnabled
        case resetCreditAlertsEnabled
        case exportsStatusJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decodeIfPresent(LanguagePreference.self, forKey: .language) ?? .system
        appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
        statusBarDisplayStyle = try container.decodeIfPresent(StatusBarDisplayStyle.self, forKey: .statusBarDisplayStyle) ?? .meters
        statusBarMetersDetailStyle = try container.decodeIfPresent(StatusBarMetersDetailStyle.self, forKey: .statusBarMetersDetailStyle) ?? .remainingPercent
        statusBarBatteryScope = try container.decodeIfPresent(StatusBarBatteryScope.self, forKey: .statusBarBatteryScope) ?? .fiveHour
        statusBarBatteryDetailStyle = try container.decodeIfPresent(StatusBarBatteryDetailStyle.self, forKey: .statusBarBatteryDetailStyle) ?? .countdown
        refreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 300
        apiCostSummaryRange = try container.decodeIfPresent(ApiCostSummaryRange.self, forKey: .apiCostSummaryRange) ?? .today
        showsCostSummary = try container.decodeIfPresent(Bool.self, forKey: .showsCostSummary) ?? true
        showsRecentSessions = try container.decodeIfPresent(Bool.self, forKey: .showsRecentSessions) ?? false
        showsSessionRepairSummary = try container.decodeIfPresent(Bool.self, forKey: .showsSessionRepairSummary) ?? true
        showsRateLimitResetToday = try container.decodeIfPresent(Bool.self, forKey: .showsRateLimitResetToday) ?? true
        showsTokenUsageHeatmap = try container.decodeIfPresent(Bool.self, forKey: .showsTokenUsageHeatmap) ?? true
        rateLimitResetTodayRefreshIntervalSeconds = Self.clampRateLimitResetTodayRefreshInterval(
            try container.decodeIfPresent(Int.self, forKey: .rateLimitResetTodayRefreshIntervalSeconds)
                ?? Self.defaultRateLimitResetTodayRefreshIntervalSeconds)
        automaticallyChecksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyChecksForUpdates) ?? true
        quotaAlertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .quotaAlertsEnabled) ?? false
        resetCreditAlertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .resetCreditAlertsEnabled) ?? false
        exportsStatusJSON = try container.decodeIfPresent(Bool.self, forKey: .exportsStatusJSON) ?? false
    }
}

public struct PreferencesStore {
    private let defaults: UserDefaults
    private let key = "runway.preferences"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> RunwayPreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(RunwayPreferences.self, from: data)
        else { return RunwayPreferences() }
        return preferences
    }

    public func save(_ preferences: RunwayPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
