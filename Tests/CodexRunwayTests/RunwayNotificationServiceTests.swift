import CodexRunwayCore
import Foundation
import Testing
@testable import CodexRunway

@Suite("Runway notifications")
struct RunwayNotificationServiceTests {
    @Test("completed reset notifications explain all reset types")
    func completedResetNotificationsExplainTypes() {
        let service = RunwayNotificationService()
        let l10n = L10n(language: .english)
        let cases: [(RateLimitResetType, String, String)] = [
            (
                .global,
                "Codex Global reset confirmed",
                "A Codex quota reset was just detected for today."),
            (
                .banked,
                "Codex Reset bank confirmed",
                "A reset credit is stored for on-demand use; it does not automatically refresh the current quota."),
            (
                .globalAndBanked,
                "Codex Global reset + reset bank confirmed",
                "The global reset completed; a separate reset credit is stored for on-demand use and does not itself refresh the current quota."),
        ]

        for (resetType, expectedTitle, expectedBody) in cases {
            let alert = RunwayAlert(
                id: "detected-\(resetType.rawValue)",
                kind: .rateLimitResetDetected,
                name: "post-id",
                threshold: nil,
                date: nil,
                resetType: resetType)

            #expect(service.title(for: alert, l10n: l10n) == expectedTitle)
            #expect(service.body(for: alert, l10n: l10n) == expectedBody)
        }
    }

    @Test("60 and 30 minute reminders name every reset type")
    func upcomingResetNotificationsNameTypes() {
        let service = RunwayNotificationService()
        let l10n = L10n(language: .english)
        let names: [(RateLimitResetType, String)] = [
            (.global, "Global reset"),
            (.banked, "Reset bank"),
            (.globalAndBanked, "Global reset + reset bank"),
        ]

        for (resetType, name) in names {
            for (threshold, expectedBody) in [
                (60, "A scheduled Codex reset is less than 1 hour away."),
                (30, "A scheduled Codex reset is less than 30 minutes away."),
            ] {
                let alert = RunwayAlert(
                    id: "upcoming-\(resetType.rawValue)-\(threshold)",
                    kind: .rateLimitResetUpcoming,
                    name: "post-id",
                    threshold: threshold,
                    date: nil,
                    resetType: resetType)

                #expect(service.title(for: alert, l10n: l10n) == "Codex \(name) approaching")
                #expect(service.body(for: alert, l10n: l10n) == expectedBody)
            }
        }
    }

    @Test("date-range reminders name every reset type")
    func dateRangeNotificationsNameTypes() throws {
        let now = try Date("2026-08-10T06:00:00Z", strategy: .iso8601)
        var singapore = Calendar(identifier: .gregorian)
        singapore.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
        let service = RunwayNotificationService()
        let l10n = L10n(language: .english)
        let names: [(RateLimitResetType, String)] = [
            (.global, "Global reset"),
            (.banked, "Reset bank"),
            (.globalAndBanked, "Global reset + reset bank"),
        ]

        for (resetType, name) in names {
            let alert = RunwayAlert(
                id: "range-\(resetType.rawValue)",
                kind: .rateLimitResetUpcoming,
                name: "post-id",
                threshold: 60,
                date: try Date("2026-08-10T07:00:00Z", strategy: .iso8601),
                endDate: try Date("2026-08-11T06:59:00Z", strategy: .iso8601),
                resetType: resetType)

            #expect(service.title(for: alert, l10n: l10n, now: now) == "Expected Codex \(name) window")
            #expect(service.body(for: alert, l10n: l10n, calendar: singapore, now: now)
                == "Expected reset window: 2026/8/10 15:00~2026/8/11 14:59.")
        }
    }

    @Test("date-only scheduled reset notification states the full local range")
    func dateOnlyScheduleNotificationUsesLocalRange() throws {
        let now = try Date("2026-08-10T06:00:00Z", strategy: .iso8601)
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
            l10n: L10n(language: .simplifiedChinese),
            now: now)
        let body = service.body(
            for: alert,
            l10n: L10n(language: .simplifiedChinese),
            calendar: singapore,
            now: now)

        #expect(title == "预计 Codex 重置时间范围")
        #expect(body == "预计重置时间范围：2026/8/10 15:00~2026/8/11 14:59。")
    }

    @Test("exact scheduled reset notification keeps the point-in-time reminder")
    func exactScheduleNotificationKeepsPointReminder() throws {
        let now = try Date("2026-08-10T06:30:00Z", strategy: .iso8601)
        let alert = RunwayAlert(
            id: "scheduled-exact",
            kind: .rateLimitResetUpcoming,
            name: "post-id",
            threshold: 30,
            date: try Date("2026-08-10T07:00:00Z", strategy: .iso8601))
        let service = RunwayNotificationService()
        let l10n = L10n(language: .simplifiedChinese)

        #expect(service.title(for: alert, l10n: l10n, now: now) == "即将重置")
        #expect(service.body(for: alert, l10n: l10n, now: now) == "计划中的 Codex 重置将在 30 分钟内到来。")
    }

    @Test("explicit reminder includes local time and confidence")
    func explicitReminderIncludesTimeAndConfidence() throws {
        let now = try Date("2026-08-10T06:30:00Z", strategy: .iso8601)
        var singapore = Calendar(identifier: .gregorian)
        singapore.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
        let alert = RunwayAlert(
            id: "scheduled-detail",
            kind: .rateLimitResetUpcoming,
            name: "post-id",
            threshold: 30,
            date: try Date("2026-08-10T07:00:00Z", strategy: .iso8601),
            resetType: .global,
            scheduleBasis: .explicit,
            confidencePercent: 92)

        let body = RunwayNotificationService().body(
            for: alert,
            l10n: L10n(language: .simplifiedChinese),
            calendar: singapore,
            now: now)

        #expect(body == "计划时间：2026/8/10 15:00 · 置信度 92% · 计划中的 Codex 重置将在 30 分钟内到来。")
    }

    @Test("inferred reminder is a preview and never an explicit promise")
    func inferredReminderPreservesPreviewSemantics() throws {
        let now = try Date("2026-08-10T06:00:00Z", strategy: .iso8601)
        var singapore = Calendar(identifier: .gregorian)
        singapore.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
        let alert = RunwayAlert(
            id: "preview-range",
            kind: .rateLimitResetUpcoming,
            name: "post-id",
            threshold: 60,
            date: try Date("2026-08-10T07:00:00Z", strategy: .iso8601),
            endDate: try Date("2026-08-11T06:59:00Z", strategy: .iso8601),
            resetType: .banked,
            scheduleBasis: .contextualInference,
            confidencePercent: 76)
        let service = RunwayNotificationService()
        let l10n = L10n(language: .english)

        #expect(service.title(for: alert, l10n: l10n, now: now) == "Codex Reset bank preview")
        #expect(service.body(for: alert, l10n: l10n, calendar: singapore, now: now)
            == "Inferred window: 2026/8/10 15:00~2026/8/11 14:59 · 76% confidence; the source did not explicitly promise a reset.")
    }

    @Test("late delivery uses past tense and does not imply completion")
    func lateDeliveryUsesPastTense() throws {
        var singapore = Calendar(identifier: .gregorian)
        singapore.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
        let now = try Date("2026-08-10T08:00:00Z", strategy: .iso8601)
        let alert = RunwayAlert(
            id: "late-preview",
            kind: .rateLimitResetUpcoming,
            name: "post-id",
            threshold: 30,
            date: try Date("2026-08-10T07:00:00Z", strategy: .iso8601),
            resetType: .global,
            scheduleBasis: .contextualInference,
            confidencePercent: 76)
        let service = RunwayNotificationService()
        let l10n = L10n(language: .simplifiedChinese)

        #expect(service.title(for: alert, l10n: l10n, now: now) == "Codex 全局重置计划时间已过")
        #expect(service.body(for: alert, l10n: l10n, calendar: singapore, now: now)
            == "推断时间 2026/8/10 15:00 已过，但尚无完成确认；原文未明确承诺重置")
    }

    @Test("legacy inferred alert stays a preview when confidence is absent")
    func legacyInferredAlertStaysPreview() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try Date("2026-08-10T06:00:00Z", strategy: .iso8601)
        let alert = RunwayAlert(
            id: "legacy-preview",
            kind: .rateLimitResetUpcoming,
            name: "post-id",
            threshold: 60,
            date: try Date("2026-08-10T07:00:00Z", strategy: .iso8601),
            scheduleBasis: .contextualInference)
        let service = RunwayNotificationService()
        let l10n = L10n(language: .english)

        #expect(service.title(for: alert, l10n: l10n, now: now) == "Codex reset preview")
        #expect(service.body(for: alert, l10n: l10n, calendar: utc, now: now)
            == "Inferred preview for 2026/8/10 07:00; the source did not explicitly promise a reset.")
    }

    @Test("range remains pending through its displayed final minute")
    func rangeUsesExclusivePendingBoundary() throws {
        let alert = RunwayAlert(
            id: "range-boundary",
            kind: .rateLimitResetUpcoming,
            name: "post-id",
            threshold: 60,
            date: try Date("2026-08-10T07:00:00Z", strategy: .iso8601),
            endDate: try Date("2026-08-11T06:59:00Z", strategy: .iso8601),
            resetType: .global,
            scheduleBasis: .explicit,
            confidencePercent: 90)
        let service = RunwayNotificationService()
        let l10n = L10n(language: .english)

        let duringFinalMinute = try Date("2026-08-11T06:59:30Z", strategy: .iso8601)
        #expect(service.title(for: alert, l10n: l10n, now: duringFinalMinute)
            == "Expected Codex Global reset window")

        let pendingUntil = try Date("2026-08-11T07:00:00Z", strategy: .iso8601)
        #expect(service.title(for: alert, l10n: l10n, now: pendingUntil)
            == "Codex Global reset schedule passed")
    }
}
