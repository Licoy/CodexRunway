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

        let sections = RunwayMainPanelSections.visible(
            provider: .grok,
            preferences: preferences)

        #expect(sections == [
            .grokQuota,
            .grokTokenHeatmap,
            .grokAPICost,
            .grokRecentSessions,
        ])
        #expect(sections.isDisjoint(with: [
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

        let sections = RunwayMainPanelSections.visible(
            provider: .codex,
            preferences: preferences)

        #expect(sections == [.codexQuota, .codexResetCredits])
    }
}
