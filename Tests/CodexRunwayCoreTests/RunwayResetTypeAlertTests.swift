import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Reset-type alert decisions")
struct RunwayResetTypeAlertTests {
    @Test("first load stays silent for completed resets")
    func firstLoadStaysSilent() throws {
        let now = try alertDate("2026-08-23T12:00:00Z")
        let current = alertSnapshot(
            now: now,
            events: [
                alertEvent(
                    postID: "100",
                    resetType: .banked,
                    announcedAt: try alertDate("2026-08-23T10:00:00Z")),
            ])

        #expect(
            RunwayAlertDecider.rateLimitResetTodayAlerts(
                previous: nil,
                current: current,
                now: now,
                calendar: alertCalendar)
                .isEmpty)
    }

    @Test("new same-day occurrences alert once in chronological stable order")
    func newOccurrencesUseIdentityAndStableOrder() throws {
        let now = try alertDate("2026-08-23T12:00:00Z")
        let existing = alertEvent(
            postID: "050",
            resetType: .global,
            announcedAt: try alertDate("2026-08-23T01:00:00Z"))
        let previous = alertSnapshot(now: now, events: [existing])
        let current = alertSnapshot(
            now: now,
            events: [
                alertEvent(
                    postID: "300",
                    resetType: .banked,
                    announcedAt: try alertDate("2026-08-23T04:00:00Z")),
                existing,
                alertEvent(
                    postID: "200",
                    resetType: .global,
                    announcedAt: try alertDate("2026-08-23T04:00:00Z")),
                alertEvent(
                    postID: "100",
                    resetType: .global,
                    announcedAt: try alertDate("2026-08-23T03:00:00Z")),
            ])

        let alerts = RunwayAlertDecider.rateLimitResetTodayAlerts(
            previous: previous,
            current: current,
            now: now,
            calendar: alertCalendar)
        let day = Int(alertCalendar.startOfDay(for: now).timeIntervalSince1970)

        #expect(alerts.map(\.name) == ["100", "200", "300"])
        #expect(alerts.map(\.resetType) == [.global, .global, .banked])
        #expect(alerts.map(\.id) == [
            "rate-limit-reset:detected:100:\(day)",
            "rate-limit-reset:detected:200:\(day)",
            "rate-limit-reset:detected:300:\(day)",
        ])
    }

    @Test("type correction keeps the same occurrence seen")
    func typeCorrectionDoesNotRedetect() throws {
        let now = try alertDate("2026-08-23T12:00:00Z")
        let announcedAt = try alertDate("2026-08-23T10:00:00Z")
        let previous = alertSnapshot(
            now: now,
            events: [alertEvent(postID: "100", resetType: .global, announcedAt: announcedAt)])
        let current = alertSnapshot(
            now: now,
            events: [alertEvent(postID: "100", resetType: .banked, announcedAt: announcedAt)])

        #expect(
            RunwayAlertDecider.rateLimitResetTodayAlerts(
                previous: previous,
                current: current,
                now: now,
                calendar: alertCalendar)
                .isEmpty)
    }

    @Test("manual completion uses its manual identity and merged schedule type")
    func manualCompletionUsesManualIdentity() throws {
        let now = try alertDate("2026-08-23T12:00:00Z")
        let banked = alertEvent(
            postID: "900",
            kind: .resetScheduled,
            resetType: .banked,
            announcedAt: try alertDate("2026-08-23T01:00:00Z"),
            effectiveAt: try alertDate("2026-08-23T03:00:00Z"))
        let global = alertEvent(
            postID: "901",
            kind: .resetScheduled,
            resetType: .global,
            announcedAt: try alertDate("2026-08-23T01:05:00Z"),
            effectiveAt: try alertDate("2026-08-23T03:00:00Z"))
        let completion = RateLimitResetManualCompletion(
            id: "manual:mixed-1",
            completedAt: try alertDate("2026-08-23T04:00:00Z"),
            visibleUntil: try alertDate("2026-08-24T04:00:00Z"),
            representativePostID: "900",
            schedulePostIDs: ["900", "901"],
            schedules: [banked, global])
        let previous = alertSnapshot(
            now: now,
            timeline: RateLimitResetTimeline())
        let current = alertSnapshot(
            now: now,
            timeline: RateLimitResetTimeline(manualCompletions: [completion]))

        let alert = try #require(
            RunwayAlertDecider.rateLimitResetTodayAlerts(
                previous: previous,
                current: current,
                now: now,
                calendar: alertCalendar)
                .first)
        let day = Int(alertCalendar.startOfDay(for: now).timeIntervalSince1970)

        #expect(alert.id == "rate-limit-reset:detected:manual:mixed-1:\(day)")
        #expect(alert.name == "900")
        #expect(alert.resetType == .globalAndBanked)
        #expect(alert.date == completion.completedAt)
    }

    @Test("upcoming alert carries type without changing its identity")
    func upcomingAlertCarriesTypeWithoutChangingID() throws {
        let now = try alertDate("2026-08-23T12:00:00Z")
        let effectiveAt = try alertDate("2026-08-23T12:25:00Z")
        let globalSnapshot = alertSnapshot(
            now: now,
            events: [alertEvent(
                postID: "500",
                kind: .resetScheduled,
                resetType: .global,
                announcedAt: try alertDate("2026-08-23T10:00:00Z"),
                effectiveAt: effectiveAt)])
        let bankedSnapshot = alertSnapshot(
            now: now,
            events: [alertEvent(
                postID: "500",
                kind: .resetScheduled,
                resetType: .banked,
                announcedAt: try alertDate("2026-08-23T10:00:00Z"),
                effectiveAt: effectiveAt)])

        let globalAlert = try #require(RunwayAlertDecider.rateLimitResetTodayAlerts(
            previous: globalSnapshot,
            current: globalSnapshot,
            now: now,
            calendar: alertCalendar).first)
        let bankedAlert = try #require(RunwayAlertDecider.rateLimitResetTodayAlerts(
            previous: globalSnapshot,
            current: bankedSnapshot,
            now: now,
            calendar: alertCalendar).first)

        #expect(globalAlert.id == bankedAlert.id)
        #expect(globalAlert.id == "rate-limit-reset:upcoming:500:30:\(Int(effectiveAt.timeIntervalSince1970))")
        #expect(globalAlert.resetType == .global)
        #expect(bankedAlert.resetType == .banked)
    }

    @Test("alerts encoded before reset types remain decodable")
    func legacyAlertRemainsDecodable() throws {
        let data = Data(#"{"id":"legacy","kind":"rateLimitResetDetected","name":"100","threshold":null,"date":null,"endDate":null}"#.utf8)
        let alert = try JSONDecoder().decode(RunwayAlert.self, from: data)

        #expect(alert.resetType == nil)
    }
}

private let alertCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

private func alertDate(_ value: String) throws -> Date {
    try Date(value, strategy: .iso8601)
}

private func alertEvent(
    postID: String,
    kind: RateLimitResetTodayEventKind = .resetCompleted,
    resetType: RateLimitResetType,
    announcedAt: Date,
    effectiveAt: Date? = nil) -> RateLimitResetTodayEvent
{
    RateLimitResetTodayEvent(
        kind: kind,
        resetType: resetType,
        announcedAt: announcedAt,
        effectiveAt: effectiveAt,
        schedulePrecision: kind == .resetScheduled ? .datetime : nil,
        scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
        source: RateLimitResetTodaySource(
            handle: "thsottiaux",
            postID: postID,
            url: URL(string: "https://x.com/thsottiaux/status/\(postID)")!),
        confidence: 1,
        rationale: "alert fixture",
        text: "alert fixture")
}

private func alertSnapshot(
    now: Date,
    events: [RateLimitResetTodayEvent] = [],
    timeline: RateLimitResetTimeline? = nil) -> RateLimitResetTodaySnapshot
{
    RateLimitResetTodaySnapshot(
        response: RateLimitResetTodayResponse(
            schemaVersion: 1,
            generatedAt: now,
            lastSuccessfulCheckAt: now,
            monitor: RateLimitResetTodayMonitor(status: .ok),
            events: events,
            resetTimeline: timeline),
        now: now,
        calendar: alertCalendar)
}
