import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Runway main panel sections")
struct RunwayMainPanelSectionsTests {
    @Test("Grok never exposes Codex-only sections")
    func grokHidesCodexSections() {
        var preferences = RunwayPreferences()
        preferences.showsTokenUsageHeatmap = true
        preferences.showsRateLimitResetToday = true
        preferences.showsCostSummary = true
        preferences.showsSessionRepairSummary = true
        preferences.showsRecentSessions = true

        let sections = RunwayMainPanelSections.orderedVisible(
            provider: .grok,
            preferences: preferences)

        #expect(sections == [
            .grokQuota,
            .grokTokenHeatmap,
            .grokResetCredits,
            .grokAPICost,
            .grokRecentSessions,
        ])
        #expect(Set(sections).isDisjoint(with: [
            .codexQuota,
            .codexTokenHeatmap,
            .codexRateLimitResetToday,
            .codexResetCredits,
            .codexAPICost,
            .codexSessionRepair,
            .codexRecentSessions,
        ]))
    }

    @Test("Codex section preferences retain their existing behavior")
    func codexUsesPreferences() {
        var preferences = RunwayPreferences()
        preferences.showsTokenUsageHeatmap = false
        preferences.showsRateLimitResetToday = false
        preferences.showsCostSummary = false
        preferences.showsSessionRepairSummary = false
        preferences.showsRecentSessions = false

        let sections = RunwayMainPanelSections.orderedVisible(
            provider: .codex,
            preferences: preferences)

        #expect(sections == [.codexQuota, .codexResetCredits])
    }

    @Test("custom order is shared while each provider filters unsupported modules")
    func customOrderFiltersByProvider() {
        var preferences = RunwayPreferences()
        preferences.mainPanelModuleOrder = [
            .recentSessions,
            .sessionRepair,
            .apiCost,
            .resetCredits,
            .rateLimitResetToday,
            .tokenUsage,
            .quota,
        ]
        preferences.showsRecentSessions = true

        #expect(RunwayMainPanelSections.orderedVisible(provider: .codex, preferences: preferences) == [
            .codexRecentSessions,
            .codexSessionRepair,
            .codexAPICost,
            .codexResetCredits,
            .codexRateLimitResetToday,
            .codexTokenHeatmap,
            .codexQuota,
        ])
        #expect(RunwayMainPanelSections.orderedVisible(provider: .grok, preferences: preferences) == [
            .grokRecentSessions,
            .grokAPICost,
            .grokResetCredits,
            .grokTokenHeatmap,
            .grokQuota,
        ])
    }

    @Test("quota and reset credits can be hidden without changing order")
    func hidesPreviouslyRequiredModules() {
        var preferences = RunwayPreferences()
        let order = preferences.mainPanelModuleOrder
        preferences.showsQuotaSummary = false
        preferences.showsResetCreditsSummary = false

        let sections = RunwayMainPanelSections.orderedVisible(
            provider: .codex,
            preferences: preferences)

        #expect(!sections.contains(.codexQuota))
        #expect(!sections.contains(.codexResetCredits))
        #expect(preferences.mainPanelModuleOrder == order)
    }
}
