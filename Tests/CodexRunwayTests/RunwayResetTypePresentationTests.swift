import CodexRunwayCore
import Foundation
import Testing
@testable import CodexRunway

@Suite("Reset type presentation")
@MainActor
struct RunwayResetTypePresentationTests {
    @Test("menu, details, and widget keep current and next reset types distinct")
    func resetTypePresentationUsesSnapshotDerivation() async throws {
        let now = Date()
        var snapshot = RateLimitResetTodaySnapshot.devMock(kind: .yes, now: now)
        snapshot.events.append(scheduledBankedReset(at: now.addingTimeInterval(3_600)))

        let defaults = UserDefaults(suiteName: "codex-runway-reset-type-\(UUID().uuidString)")!
        let settings = RunwaySettings(store: PreferencesStore(defaults: defaults))
        settings.updateLanguage(.simplifiedChinese)
        settings.updateShowsRateLimitResetToday(true)
        settings.updateRateLimitResetTodayAlertsEnabled(false)
        let model = RunwayModel(
            settings: settings,
            services: services(snapshot: snapshot),
            accountStore: isolatedAccountStore())

        model.refreshRateLimitResetToday()
        for _ in 0..<100 where model.rateLimitResetToday == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.rateLimitResetTodayText == "是 · 全局重置")
        let nextLine = try #require(model.rateLimitResetTodayLines.first {
            $0.title == "预计下次重置"
        })
        #expect(nextLine.value.contains("重置银行 · "))
        let widget = try #require(model.makeWidgetSnapshot(now: now).resetToday)
        #expect(widget.resetType == .global)
        #expect(widget.nextScheduledResetType == .banked)
    }

    private func scheduledBankedReset(at effectiveAt: Date) -> RateLimitResetTodayEvent {
        RateLimitResetTodayEvent(
            kind: .resetScheduled,
            resetType: .banked,
            announcedAt: effectiveAt.addingTimeInterval(-3_600),
            effectiveAt: effectiveAt,
            schedulePrecision: .datetime,
            scheduleBasis: .explicit,
            scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
            source: RateLimitResetTodaySource(
                handle: "thsottiaux",
                postID: "2090000000000000001",
                url: URL(string: "https://x.com/thsottiaux/status/2090000000000000001")!),
            confidence: 0.99,
            rationale: "Explicit Codex reset-bank credit schedule.",
            text: "A reset-bank credit is scheduled.")
    }

    private func services(snapshot: RateLimitResetTodaySnapshot) -> RunwayModelServices {
        RunwayModelServices(
            loadValidAuth: { _, _ in throw URLError(.userAuthenticationRequired) },
            fetchQuota: { _ in throw URLError(.badServerResponse) },
            fetchResetCredits: { _ in throw URLError(.badServerResponse) },
            fetchRateLimitResetToday: { snapshot },
            scanAPIEquivalent: { _, _, _, _ in throw URLError(.badServerResponse) },
            fetchDailyWorkspaceUsage: { _, _, _, _, _ in throw URLError(.badServerResponse) },
            fetchCodexProfileTokenUsage: { _ in throw URLError(.badServerResponse) },
            dryRunSessions: { throw URLError(.badServerResponse) },
            scanRecentSessions: { _ in throw URLError(.badServerResponse) })
    }

    private func isolatedAccountStore() -> AccountStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-reset-type-test-\(UUID().uuidString)", isDirectory: true)
        return AccountStore(
            rootURL: root.appendingPathComponent("accounts", isDirectory: true),
            officialAuthURL: root.appendingPathComponent("auth.json"))
    }
}
