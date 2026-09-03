import Foundation

public enum LanguagePreference: String, CaseIterable, Codable, Sendable {
    case system
    case english
    case simplifiedChinese
    case traditionalChinese
    case korean
    case japanese
    case russian
    case french
}

public enum ResolvedLanguage: String, CaseIterable, Codable, Sendable, Equatable {
    case english
    case simplifiedChinese
    case traditionalChinese
    case korean
    case japanese
    case russian
    case french
}

public enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark
}

public enum MainPanelBackgroundStyle: String, CaseIterable, Codable, Sendable {
    case translucent
    case opaque
}

public enum StatusBarDisplayStyle: String, CaseIterable, Codable, Sendable {
    case meters
    case countdown
    case battery
    case rings
    case text
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

/// Which platforms contribute meters to the menu-bar status item.
public enum StatusBarProviderScope: String, CaseIterable, Codable, Sendable {
    /// Follow the main panel's `selectedProvider` (legacy single-platform bar).
    case selected
    /// Show Codex on top and Grok below (one priority window each).
    case both
}

public enum ApiCostSummaryRange: String, CaseIterable, Codable, Sendable {
    case today
    case current
    case previous
    case thisMonth
}

public enum TokenUsageChartStyle: String, CaseIterable, Codable, Sendable, Hashable {
    case heatmap
    case line
    case bar
}

public enum MainPanelModule: String, CaseIterable, Codable, Sendable, Hashable {
    case quota
    case tokenUsage
    case rateLimitResetToday
    case quotaEstimate
    case resetCredits
    case apiCost
    case sessionRepair
    case recentSessions
}

public struct RunwayPreferences: Codable, Sendable, Equatable {
    public var selectedProvider: RunwayProvider
    public var language: LanguagePreference
    public var appearance: AppearancePreference
    public var mainPanelBackgroundStyle: MainPanelBackgroundStyle
    public var statusBarDisplayStyle: StatusBarDisplayStyle
    public var statusBarMetersDetailStyle: StatusBarMetersDetailStyle
    public var statusBarBatteryScope: StatusBarBatteryScope
    public var statusBarBatteryDetailStyle: StatusBarBatteryDetailStyle
    public var statusBarProviderScope: StatusBarProviderScope
    public var refreshIntervalSeconds: Int
    public var widgetRefreshIntervalSeconds: Int
    public var apiCostSummaryRange: ApiCostSummaryRange
    public var mainPanelHeight: Double
    public var mainPanelModuleOrder: [MainPanelModule]
    public var showsQuotaSummary: Bool
    public var showsResetCreditsSummary: Bool
    public var showsQuotaEstimateSummary: Bool
    public var quotaEstimateWindowMode: QuotaEstimateWindowMode
    public var showsCostSummary: Bool
    public var showsRecentSessions: Bool
    public var showsSessionRepairSummary: Bool
    public var showsRateLimitResetToday: Bool
    public var showsModelSpecificQuotaUsage: Bool
    public var showsTokenUsageHeatmap: Bool
    public var tokenUsageChartStyle: TokenUsageChartStyle
    public var rateLimitResetTodayRefreshIntervalSeconds: Int
    public var automaticallyChecksForUpdates: Bool
    public var quotaAlertsEnabled: Bool
    public var resetCreditAlertsEnabled: Bool
    public var rateLimitResetTodayAlertsEnabled: Bool
    public var exportsStatusJSON: Bool

    public static let widgetRefreshIntervalOptions: [Int] = [60, 300, 600, 900, 1_800]
    public static let defaultWidgetRefreshIntervalSeconds = 60
    public static let defaultMainPanelHeight = 584.0
    public static let minimumMainPanelHeight = 360.0
    public static let maximumMainPanelHeight = 900.0
    public static let rateLimitResetTodayRefreshIntervalOptions: [Int] = [
        300, 600, 900, 1_800, 3_600, 7_200, 21_600,
    ]
    public static let defaultRateLimitResetTodayRefreshIntervalSeconds = 300
    public static let defaultMainPanelModuleOrder: [MainPanelModule] = [
        .quota,
        .tokenUsage,
        .rateLimitResetToday,
        .quotaEstimate,
        .resetCredits,
        .apiCost,
        .sessionRepair,
        .recentSessions,
    ]

    public init(
        selectedProvider: RunwayProvider = .codex,
        language: LanguagePreference = .system,
        appearance: AppearancePreference = .system,
        mainPanelBackgroundStyle: MainPanelBackgroundStyle = .translucent,
        statusBarDisplayStyle: StatusBarDisplayStyle = .meters,
        statusBarMetersDetailStyle: StatusBarMetersDetailStyle = .remainingPercent,
        statusBarBatteryScope: StatusBarBatteryScope = .fiveHour,
        statusBarBatteryDetailStyle: StatusBarBatteryDetailStyle = .countdown,
        statusBarProviderScope: StatusBarProviderScope = .selected,
        refreshIntervalSeconds: Int = 300,
        widgetRefreshIntervalSeconds: Int = RunwayPreferences.defaultWidgetRefreshIntervalSeconds,
        apiCostSummaryRange: ApiCostSummaryRange = .today,
        mainPanelHeight: Double = RunwayPreferences.defaultMainPanelHeight,
        mainPanelModuleOrder: [MainPanelModule] = RunwayPreferences.defaultMainPanelModuleOrder,
        showsQuotaSummary: Bool = true,
        showsResetCreditsSummary: Bool = true,
        showsQuotaEstimateSummary: Bool = true,
        quotaEstimateWindowMode: QuotaEstimateWindowMode = .auto,
        showsCostSummary: Bool = true,
        showsRecentSessions: Bool = false,
        showsSessionRepairSummary: Bool = true,
        showsRateLimitResetToday: Bool = true,
        showsModelSpecificQuotaUsage: Bool = false,
        showsTokenUsageHeatmap: Bool = true,
        tokenUsageChartStyle: TokenUsageChartStyle = .heatmap,
        rateLimitResetTodayRefreshIntervalSeconds: Int = RunwayPreferences.defaultRateLimitResetTodayRefreshIntervalSeconds,
        automaticallyChecksForUpdates: Bool = true,
        quotaAlertsEnabled: Bool = false,
        resetCreditAlertsEnabled: Bool = false,
        rateLimitResetTodayAlertsEnabled: Bool = true,
        exportsStatusJSON: Bool = false)
    {
        self.selectedProvider = selectedProvider
        self.language = language
        self.appearance = appearance
        self.mainPanelBackgroundStyle = mainPanelBackgroundStyle
        self.statusBarDisplayStyle = statusBarDisplayStyle
        self.statusBarMetersDetailStyle = statusBarMetersDetailStyle
        self.statusBarBatteryScope = statusBarBatteryScope
        self.statusBarBatteryDetailStyle = statusBarBatteryDetailStyle
        self.statusBarProviderScope = statusBarProviderScope
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.widgetRefreshIntervalSeconds = Self.clampWidgetRefreshInterval(widgetRefreshIntervalSeconds)
        self.apiCostSummaryRange = apiCostSummaryRange
        self.mainPanelHeight = Self.clampMainPanelHeight(mainPanelHeight)
        self.mainPanelModuleOrder = Self.normalizedMainPanelModuleOrder(mainPanelModuleOrder)
        self.showsQuotaSummary = showsQuotaSummary
        self.showsResetCreditsSummary = showsResetCreditsSummary
        self.showsQuotaEstimateSummary = showsQuotaEstimateSummary
        self.quotaEstimateWindowMode = quotaEstimateWindowMode
        self.showsCostSummary = showsCostSummary
        self.showsRecentSessions = showsRecentSessions
        self.showsSessionRepairSummary = showsSessionRepairSummary
        self.showsRateLimitResetToday = showsRateLimitResetToday
        self.showsModelSpecificQuotaUsage = showsModelSpecificQuotaUsage
        self.showsTokenUsageHeatmap = showsTokenUsageHeatmap
        self.tokenUsageChartStyle = tokenUsageChartStyle
        self.rateLimitResetTodayRefreshIntervalSeconds = Self.clampRateLimitResetTodayRefreshInterval(
            rateLimitResetTodayRefreshIntervalSeconds)
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.quotaAlertsEnabled = quotaAlertsEnabled
        self.resetCreditAlertsEnabled = resetCreditAlertsEnabled
        self.rateLimitResetTodayAlertsEnabled = rateLimitResetTodayAlertsEnabled
        self.exportsStatusJSON = exportsStatusJSON
    }

    public static func clampRateLimitResetTodayRefreshInterval(_ seconds: Int) -> Int {
        max(300, min(21_600, seconds))
    }

    public static func clampWidgetRefreshInterval(_ seconds: Int) -> Int {
        max(60, min(1_800, seconds))
    }

    public static func clampMainPanelHeight(_ height: Double) -> Double {
        guard height.isFinite else { return defaultMainPanelHeight }
        return max(minimumMainPanelHeight, min(maximumMainPanelHeight, height))
    }

    public static func normalizedMainPanelModuleOrder(
        _ order: [MainPanelModule]
    ) -> [MainPanelModule] {
        var seen = Set<MainPanelModule>()
        var result = order.filter { seen.insert($0).inserted }
        for module in defaultMainPanelModuleOrder where seen.insert(module).inserted {
            if let neighbor = defaultMainPanelModuleOrder
                .drop(while: { $0 != module })
                .dropFirst()
                .first(where: { result.contains($0) }),
               let index = result.firstIndex(of: neighbor)
            {
                result.insert(module, at: index)
            } else {
                result.append(module)
            }
        }
        return result
    }

    public mutating func moveMainPanelModule(_ module: MainPanelModule, by offset: Int) {
        var order = Self.normalizedMainPanelModuleOrder(mainPanelModuleOrder)
        guard let source = order.firstIndex(of: module) else { return }
        let destination = source + offset
        guard order.indices.contains(destination) else { return }
        order.swapAt(source, destination)
        mainPanelModuleOrder = order
    }

    public mutating func resetMainPanelModuleOrder() {
        mainPanelModuleOrder = Self.defaultMainPanelModuleOrder
    }

    enum CodingKeys: String, CodingKey {
        case selectedProvider
        case language
        case appearance
        case mainPanelBackgroundStyle
        case statusBarDisplayStyle
        case statusBarMetersDetailStyle
        case statusBarBatteryScope
        case statusBarBatteryDetailStyle
        case statusBarProviderScope
        case refreshIntervalSeconds
        case widgetRefreshIntervalSeconds
        case apiCostSummaryRange
        case mainPanelHeight
        case mainPanelModuleOrder
        case showsQuotaSummary
        case showsResetCreditsSummary
        case showsQuotaEstimateSummary
        case quotaEstimateWindowMode
        case showsCostSummary
        case showsRecentSessions
        case showsSessionRepairSummary
        case showsRateLimitResetToday
        case showsModelSpecificQuotaUsage
        case showsTokenUsageHeatmap
        case tokenUsageChartStyle
        case rateLimitResetTodayRefreshIntervalSeconds
        case automaticallyChecksForUpdates
        case quotaAlertsEnabled
        case resetCreditAlertsEnabled
        case rateLimitResetTodayAlertsEnabled
        case exportsStatusJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedProvider = try container.decodeIfPresent(RunwayProvider.self, forKey: .selectedProvider) ?? .codex
        language = try container.decodeIfPresent(LanguagePreference.self, forKey: .language) ?? .system
        appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
        mainPanelBackgroundStyle = try container.decodeIfPresent(
            MainPanelBackgroundStyle.self,
            forKey: .mainPanelBackgroundStyle) ?? .translucent
        statusBarDisplayStyle = try container.decodeIfPresent(StatusBarDisplayStyle.self, forKey: .statusBarDisplayStyle) ?? .meters
        statusBarMetersDetailStyle = try container.decodeIfPresent(StatusBarMetersDetailStyle.self, forKey: .statusBarMetersDetailStyle) ?? .remainingPercent
        statusBarBatteryScope = try container.decodeIfPresent(StatusBarBatteryScope.self, forKey: .statusBarBatteryScope) ?? .fiveHour
        statusBarBatteryDetailStyle = try container.decodeIfPresent(StatusBarBatteryDetailStyle.self, forKey: .statusBarBatteryDetailStyle) ?? .countdown
        statusBarProviderScope = try container.decodeIfPresent(StatusBarProviderScope.self, forKey: .statusBarProviderScope) ?? .selected
        refreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 300
        widgetRefreshIntervalSeconds = Self.clampWidgetRefreshInterval(
            try container.decodeIfPresent(Int.self, forKey: .widgetRefreshIntervalSeconds)
                ?? Self.defaultWidgetRefreshIntervalSeconds)
        apiCostSummaryRange = try container.decodeIfPresent(ApiCostSummaryRange.self, forKey: .apiCostSummaryRange) ?? .today
        mainPanelHeight = Self.clampMainPanelHeight(
            try container.decodeIfPresent(Double.self, forKey: .mainPanelHeight)
                ?? Self.defaultMainPanelHeight)
        let storedModuleIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .mainPanelModuleOrder)
        let storedModuleOrder = storedModuleIDs?
            .compactMap(MainPanelModule.init(rawValue:))
            ?? Self.defaultMainPanelModuleOrder
        mainPanelModuleOrder = Self.normalizedMainPanelModuleOrder(storedModuleOrder)
        showsQuotaSummary = try container.decodeIfPresent(Bool.self, forKey: .showsQuotaSummary) ?? true
        showsResetCreditsSummary =
            try container.decodeIfPresent(Bool.self, forKey: .showsResetCreditsSummary) ?? true
        showsQuotaEstimateSummary =
            try container.decodeIfPresent(Bool.self, forKey: .showsQuotaEstimateSummary) ?? true
        quotaEstimateWindowMode =
            try container.decodeIfPresent(QuotaEstimateWindowMode.self, forKey: .quotaEstimateWindowMode)
            ?? .auto
        showsCostSummary = try container.decodeIfPresent(Bool.self, forKey: .showsCostSummary) ?? true
        showsRecentSessions = try container.decodeIfPresent(Bool.self, forKey: .showsRecentSessions) ?? false
        showsSessionRepairSummary = try container.decodeIfPresent(Bool.self, forKey: .showsSessionRepairSummary) ?? true
        showsRateLimitResetToday = try container.decodeIfPresent(Bool.self, forKey: .showsRateLimitResetToday) ?? true
        showsModelSpecificQuotaUsage =
            try container.decodeIfPresent(Bool.self, forKey: .showsModelSpecificQuotaUsage) ?? false
        showsTokenUsageHeatmap = try container.decodeIfPresent(Bool.self, forKey: .showsTokenUsageHeatmap) ?? true
        tokenUsageChartStyle = try container.decodeIfPresent(TokenUsageChartStyle.self, forKey: .tokenUsageChartStyle) ?? .heatmap
        rateLimitResetTodayRefreshIntervalSeconds = Self.clampRateLimitResetTodayRefreshInterval(
            try container.decodeIfPresent(Int.self, forKey: .rateLimitResetTodayRefreshIntervalSeconds)
                ?? Self.defaultRateLimitResetTodayRefreshIntervalSeconds)
        automaticallyChecksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyChecksForUpdates) ?? true
        quotaAlertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .quotaAlertsEnabled) ?? false
        resetCreditAlertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .resetCreditAlertsEnabled) ?? false
        rateLimitResetTodayAlertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .rateLimitResetTodayAlertsEnabled) ?? true
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
