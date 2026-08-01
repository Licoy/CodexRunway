import CodexRunwayCore
import SwiftUI

@MainActor
final class RunwaySettings: ObservableObject {
    @Published private(set) var preferences: RunwayPreferences

    var onChange: (() -> Void)?

    private let store: PreferencesStore

    init(store: PreferencesStore = PreferencesStore()) {
        self.store = store
        self.preferences = store.load()
    }

    var l10n: L10n {
        L10n(preference: preferences.language)
    }

    var colorScheme: ColorScheme? {
        switch preferences.appearance {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func updateSelectedProvider(_ provider: RunwayProvider) {
        update { $0.selectedProvider = provider }
    }

    func updateLanguage(_ language: LanguagePreference) {
        update { $0.language = language }
    }

    func updateAppearance(_ appearance: AppearancePreference) {
        update { $0.appearance = appearance }
    }

    func updateStatusBarDisplayStyle(_ style: StatusBarDisplayStyle) {
        update { $0.statusBarDisplayStyle = style }
    }

    func updateStatusBarMetersDetailStyle(_ style: StatusBarMetersDetailStyle) {
        update { $0.statusBarMetersDetailStyle = style }
    }

    func updateStatusBarBatteryScope(_ scope: StatusBarBatteryScope) {
        update { $0.statusBarBatteryScope = scope }
    }

    func updateStatusBarBatteryDetailStyle(_ style: StatusBarBatteryDetailStyle) {
        update { $0.statusBarBatteryDetailStyle = style }
    }

    func updateStatusBarProviderScope(_ scope: StatusBarProviderScope) {
        update { $0.statusBarProviderScope = scope }
    }

    func updateRefreshInterval(_ seconds: Int) {
        update { $0.refreshIntervalSeconds = max(60, min(1_800, seconds)) }
    }

    func updateApiCostSummaryRange(_ range: ApiCostSummaryRange) {
        update { $0.apiCostSummaryRange = range }
    }

    func updateShowsCostSummary(_ isShown: Bool) {
        update { $0.showsCostSummary = isShown }
    }

    func updateShowsRecentSessions(_ isShown: Bool) {
        update { $0.showsRecentSessions = isShown }
    }

    func updateShowsSessionRepairSummary(_ isShown: Bool) {
        update { $0.showsSessionRepairSummary = isShown }
    }

    func updateShowsRateLimitResetToday(_ isShown: Bool) {
        update { $0.showsRateLimitResetToday = isShown }
    }

    func updateShowsModelSpecificQuotaUsage(_ isShown: Bool) {
        update { $0.showsModelSpecificQuotaUsage = isShown }
    }

    func updateShowsTokenUsageHeatmap(_ isShown: Bool) {
        update { $0.showsTokenUsageHeatmap = isShown }
    }

    func updateTokenUsageChartStyle(_ style: TokenUsageChartStyle) {
        update { $0.tokenUsageChartStyle = style }
    }

    func updateRateLimitResetTodayRefreshInterval(_ seconds: Int) {
        update {
            $0.rateLimitResetTodayRefreshIntervalSeconds =
                RunwayPreferences.clampRateLimitResetTodayRefreshInterval(seconds)
        }
    }

    func updateAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        update { $0.automaticallyChecksForUpdates = isEnabled }
    }

    func updateQuotaAlertsEnabled(_ isEnabled: Bool) {
        update { $0.quotaAlertsEnabled = isEnabled }
    }

    func updateResetCreditAlertsEnabled(_ isEnabled: Bool) {
        update { $0.resetCreditAlertsEnabled = isEnabled }
    }

    func updateRateLimitResetTodayAlertsEnabled(_ isEnabled: Bool) {
        update { $0.rateLimitResetTodayAlertsEnabled = isEnabled }
    }

    func updateExportsStatusJSON(_ isEnabled: Bool) {
        update { $0.exportsStatusJSON = isEnabled }
    }

    private func update(_ change: (inout RunwayPreferences) -> Void) {
        var next = preferences
        change(&next)
        preferences = next
        store.save(preferences)
        onChange?()
    }
}
