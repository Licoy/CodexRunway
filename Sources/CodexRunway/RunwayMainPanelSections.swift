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
    case grokBilling
}

enum RunwayMainPanelSections {
    static func visible(
        provider: RunwayProvider,
        preferences: RunwayPreferences) -> Set<RunwayMainPanelSection>
    {
        switch provider {
        case .grok:
            return [.grokQuota, .grokBilling]
        case .codex:
            var sections: Set<RunwayMainPanelSection> = [
                .codexQuota,
                .codexResetCredits,
            ]
            if preferences.showsTokenUsageHeatmap {
                sections.insert(.codexTokenHeatmap)
            }
            if preferences.showsRateLimitResetToday {
                sections.insert(.codexRateLimitResetToday)
            }
            if preferences.showsCostSummary {
                sections.insert(.codexAPICost)
            }
            if preferences.showsSessionRepairSummary {
                sections.insert(.codexSessionRepair)
            }
            if preferences.showsRecentSessions {
                sections.insert(.codexRecentSessions)
            }
            return sections
        }
    }
}
