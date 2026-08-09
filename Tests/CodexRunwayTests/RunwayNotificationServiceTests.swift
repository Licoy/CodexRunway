import CodexRunwayCore
import Foundation
import Testing
@testable import CodexRunway

@Suite("Runway notifications")
struct RunwayNotificationServiceTests {
    @Test("date-only scheduled reset notification states the full local range")
    func dateOnlyScheduleNotificationUsesLocalRange() throws {
        var singapore = Calendar(identifier: .gregorian)
        singapore.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
        let alert = RunwayAlert(
            id: "scheduled-range",
            kind: .rateLimitResetUpcoming,
            name: "post-id",
            threshold: 60,
            date: try Date("2026-08-10T07:00:00Z", strategy: .iso8601),
            endDate: try Date("2026-08-11T06:59:00Z", strategy: .iso8601))

        let service = RunwayNotificationService()
        let title = service.title(
            for: alert,
            l10n: L10n(language: .simplifiedChinese))
        let body = service.body(
            for: alert,
            l10n: L10n(language: .simplifiedChinese),
            calendar: singapore)

        #expect(title == "预计 Codex 重置时间范围")
        #expect(body == "预计重置时间范围：2026/8/10 15:00~2026/8/11 14:59。")
    }

    @Test("exact scheduled reset notification keeps the point-in-time reminder")
    func exactScheduleNotificationKeepsPointReminder() throws {
        let alert = RunwayAlert(
            id: "scheduled-exact",
            kind: .rateLimitResetUpcoming,
            name: "post-id",
            threshold: 30,
            date: try Date("2026-08-10T07:00:00Z", strategy: .iso8601))
        let service = RunwayNotificationService()
        let l10n = L10n(language: .simplifiedChinese)

        #expect(service.title(for: alert, l10n: l10n) == "即将重置")
        #expect(service.body(for: alert, l10n: l10n) == "计划中的 Codex 重置将在 30 分钟内到来。")
    }
}
