import CodexRunwayCore

enum RunwayMainPanelSection: Hashable {
    case codexQuota
    case codexTokenHeatmap
    case codexRateLimitResetToday
    case codexResetCredits
    case codexAPICost
    case codexSessionRepair
    case codexRecentSessions
    case grokQuota
    case grokResetCredits
    case grokTokenHeatmap
    case grokAPICost
    case grokRecentSessions
}

enum RunwayMainPanelSections {
    static func orderedVisible(
        provider: RunwayProvider,
        preferences: RunwayPreferences) -> [RunwayMainPanelSection]
    {
        RunwayPreferences.normalizedMainPanelModuleOrder(preferences.mainPanelModuleOrder)
            .compactMap { section(for: $0, provider: provider, preferences: preferences) }
    }

    private static func section(
        for module: MainPanelModule,
        provider: RunwayProvider,
        preferences: RunwayPreferences
    ) -> RunwayMainPanelSection? {
        switch provider {
        case .grok:
            // Billing details live behind the included-quota info button, not a full section.
            // Reset-credits is shown only when an official snapshot exists (see the Grok panel).
            switch module {
            case .quota:
                return preferences.showsQuotaSummary ? .grokQuota : nil
            case .tokenUsage:
                return preferences.showsTokenUsageHeatmap ? .grokTokenHeatmap : nil
            case .rateLimitResetToday, .sessionRepair:
                return nil
            case .resetCredits:
                return preferences.showsResetCreditsSummary ? .grokResetCredits : nil
            case .apiCost:
                return preferences.showsCostSummary ? .grokAPICost : nil
            case .recentSessions:
                return preferences.showsRecentSessions ? .grokRecentSessions : nil
            }
        case .codex:
            switch module {
            case .quota:
                return preferences.showsQuotaSummary ? .codexQuota : nil
            case .tokenUsage:
                return preferences.showsTokenUsageHeatmap ? .codexTokenHeatmap : nil
            case .rateLimitResetToday:
                return preferences.showsRateLimitResetToday ? .codexRateLimitResetToday : nil
            case .resetCredits:
                return preferences.showsResetCreditsSummary ? .codexResetCredits : nil
            case .apiCost:
                return preferences.showsCostSummary ? .codexAPICost : nil
            case .sessionRepair:
                return preferences.showsSessionRepairSummary ? .codexSessionRepair : nil
            case .recentSessions:
                return preferences.showsRecentSessions ? .codexRecentSessions : nil
            }
        }
    }
}
