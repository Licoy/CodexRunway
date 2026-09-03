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

    func updateMainPanelBackgroundStyle(_ style: MainPanelBackgroundStyle) {
        update { $0.mainPanelBackgroundStyle = style }
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

    func updateWidgetRefreshInterval(_ seconds: Int) {
        update {
            $0.widgetRefreshIntervalSeconds = RunwayPreferences.clampWidgetRefreshInterval(seconds)
        }
    }

    func updateApiCostSummaryRange(_ range: ApiCostSummaryRange) {
        update { $0.apiCostSummaryRange = range }
    }

    /// Panel geometry only affects the hosted view. Avoid the broader settings
    /// callback, which relabels models and rebuilds unrelated status-bar content.
    func updateMainPanelHeight(_ height: CGFloat) {
        update(notify: false) {
            $0.mainPanelHeight = RunwayPreferences.clampMainPanelHeight(Double(height))
        }
    }

    func moveMainPanelModule(_ module: MainPanelModule, by offset: Int) {
        update { $0.moveMainPanelModule(module, by: offset) }
    }

    func resetMainPanelModuleOrder() {
        update { $0.resetMainPanelModuleOrder() }
    }

    func updateShowsQuotaSummary(_ isShown: Bool) {
        update { $0.showsQuotaSummary = isShown }
    }

    func updateShowsResetCreditsSummary(_ isShown: Bool) {
        update { $0.showsResetCreditsSummary = isShown }
    }

    func updateShowsQuotaEstimateSummary(_ isShown: Bool) {
        update { $0.showsQuotaEstimateSummary = isShown }
    }

    func updateQuotaEstimateWindowMode(_ mode: QuotaEstimateWindowMode) {
        update { $0.quotaEstimateWindowMode = mode }
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

    private func update(
        notify: Bool = true,
        _ change: (inout RunwayPreferences) -> Void
    ) {
        var next = preferences
        change(&next)
        preferences = next
        store.save(preferences)
        if notify {
            onChange?()
        }
    }
}
