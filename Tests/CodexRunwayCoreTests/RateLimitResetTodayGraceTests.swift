import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Rate limit reset schedule grace")
struct RateLimitResetTodayGraceTests {
    @Test("decodes resolved grace hours and keeps the legacy default when omitted")
    func decodesGraceHours() throws {
        let now = try resetStatusDate("2026-09-26T12:00:00Z")
        let missing = try ResetStatusFeedFixture(
            event: scheduledFixture(hoursJSON: nil),
            now: now)
            .decode()
        #expect(missing.events[0].scheduleGraceHours == nil)
        #expect(missing.events[0].effectiveScheduleGraceInterval == 3 * 3_600)
        #expect(missing.graceSchedules.isEmpty)

        for hours in ["0", "1.5", "24", "72", "100"] {
            let event = scheduledFixture(hoursJSON: hours)
            let snapshot = try ResetStatusFeedFixture(event: event, now: now)
                .withGraceSchedules(event.json)
                .decode()
            #expect(snapshot.events[0].scheduleGraceHours == Double(hours))
            #expect(snapshot.graceSchedules == snapshot.events)
        }
    }

    @Test("rejects invalid grace fields and a null grace schedule collection")
    func rejectsInvalidGracePayloads() throws {
        let now = try resetStatusDate("2026-09-26T12:00:00Z")
        for raw in ["null", "true", "\"3\"", "-1", "1e308"] {
            #expect(throws: DecodingError.self) {
                try ResetStatusFeedFixture(
                    event: scheduledFixture(hoursJSON: raw),
                    now: now)
                    .decode()
            }
        }

        let data = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-09-26T12:00:00Z",
          "lastSuccessfulCheckAt": "2026-09-26T12:00:00Z",
          "monitor": {"status": "ok", "errorCode": null},
          "events": [],
          "graceSchedules": null
        }
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try RateLimitResetTodaySnapshot.decode(from: data, now: now)
        }
    }

    @Test("validates grace schedule kind duration identity and duplicates")
    func validatesGraceScheduleContract() throws {
        let now = try resetStatusDate("2026-09-26T12:00:00Z")
        let scheduled = scheduledFixture(hoursJSON: "24")
        let completed = ResetStatusEventFixture(
            kind: "reset_completed",
            announcedAt: "2026-09-25T12:00:00Z")
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(eventsJSON: "", now: now)
                .withGraceSchedules(completed.json)
                .decode()
        }
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(eventsJSON: "", now: now)
                .withGraceSchedules(scheduledFixture(hoursJSON: nil).json)
                .decode()
        }
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(eventsJSON: "", now: now)
                .withGraceSchedules("\(scheduled.json),\n\(scheduled.json)")
                .decode()
        }
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(event: scheduledFixture(hoursJSON: "3"), now: now)
                .withGraceSchedules(scheduled.json)
                .decode()
        }
    }

    @Test(
        "uses each grace-only duration with a half-open deadline",
        arguments: [24.0, 72.0, 100.0])
    func graceOnlyCandidateUsesItsOwnDeadline(hours: Double) throws {
        let due = try resetStatusDate("2026-09-25T07:00:00Z")
        let event = scheduledEvent(at: due, hours: hours)
        let deadline = due.addingTimeInterval(hours * 3_600)
        let inside = deadline.addingTimeInterval(-1)
        let snapshot = makeSnapshot(now: inside, graceSchedules: [event])

        #expect(snapshot.events.isEmpty)
        #expect(snapshot.verdictPresentation(
            now: inside,
            calendar: resetStatusUTCCalendar).reason == .grace)
        let atDeadline = snapshot.verdictPresentation(
            now: deadline,
            calendar: resetStatusUTCCalendar)
        #expect(atDeadline.reason != .grace)
        #expect(!atDeadline.showsYes)
        #expect(!atDeadline.isCompleted)
        #expect(event.graceDeadline(after: due) == deadline)
        #expect(snapshot.nextVerdictTransitionDates(
            now: inside.addingTimeInterval(-1),
            calendar: resetStatusUTCCalendar).contains(
            deadline))
    }

    @Test("grace projection survives a six-event public log cap")
    func graceProjectionIsIndependentFromEvents() throws {
        let due = try resetStatusDate("2026-09-25T12:00:00Z")
        let now = due.addingTimeInterval(3_600)
        let history = (1...6).map { offset in
            completedEvent(
                at: due.addingTimeInterval(Double(-offset) * 86_400),
                postID: "\(offset + 10)")
        }
        let grace = scheduledEvent(at: due, hours: 24, postID: "1")
        let snapshot = makeSnapshot(now: now, events: history, graceSchedules: [grace])

        #expect(snapshot.events.count == 6)
        #expect(!snapshot.events.contains { $0.source.postID == "1" })
        #expect(snapshot.verdictPresentation(
            now: now,
            calendar: resetStatusUTCCalendar).reason == .grace)
    }

    @Test("zero disables grace and decimal durations remain half open")
    func zeroAndDecimalGrace() throws {
        let due = try resetStatusDate("2026-09-25T12:00:00Z")
        let disabled = makeSnapshot(
            now: due,
            graceSchedules: [scheduledEvent(at: due, hours: 0)])
        #expect(disabled.verdictPresentation(
            now: due,
            calendar: resetStatusUTCCalendar).reason == .expiredUnconfirmed)

        let decimal = makeSnapshot(
            now: due,
            graceSchedules: [scheduledEvent(at: due, hours: 1.5)])
        #expect(decimal.verdictPresentation(
            now: due.addingTimeInterval(5_399),
            calendar: resetStatusUTCCalendar).reason == .grace)
        #expect(decimal.verdictPresentation(
            now: due.addingTimeInterval(5_400),
            calendar: resetStatusUTCCalendar).reason == .expiredUnconfirmed)
    }

    @Test("same-time reset types expire independently")
    func resetTypesUseIndependentDurations() throws {
        let due = try resetStatusDate("2026-09-25T12:00:00Z")
        let global = scheduledEvent(at: due, hours: 1, postID: "1")
        let banked = scheduledEvent(at: due, hours: 4, resetType: .banked, postID: "2")
        let snapshot = makeSnapshot(now: due, graceSchedules: [global, banked])

        let presentation = snapshot.verdictPresentation(
            now: due.addingTimeInterval(2 * 3_600),
            calendar: resetStatusUTCCalendar)
        #expect(presentation.reason == .grace)
        #expect(presentation.resetType == .banked)
        #expect(presentation.evidenceEvent?.source.postID == "2")
    }

    @Test("matching completion prevents date grace from returning after midnight")
    func dateCompletionPreventsCrossDayGrace() throws {
        let effectiveAt = try resetStatusDate("2026-11-01T15:00:00Z")
        var schedule = scheduledEvent(at: effectiveAt, hours: 24)
        schedule.schedulePrecision = .date
        schedule.announcedAt = try resetStatusDate("2026-11-01T06:00:00Z")
        let completion = completedEvent(
            at: try resetStatusDate("2026-11-01T20:00:00Z"),
            postID: "2")
        let now = try resetStatusDate("2026-11-02T09:00:00Z")
        let snapshot = makeSnapshot(
            now: now,
            events: [completion],
            graceSchedules: [schedule])
        let dayStart = try resetStatusDate("2026-11-01T07:00:00Z")

        #expect(snapshot.scheduledResetWindow(for: schedule)?.startAt == dayStart)
        #expect(snapshot.verdictPresentation(
            now: now,
            calendar: resetStatusUTCCalendar).reason == .expiredUnconfirmed)
    }

    @Test("completion matching checks announcement type scope and exact lower bound")
    func completionMatchingUsesFullContract() throws {
        let due = try resetStatusDate("2026-09-25T20:00:00Z")
        var schedule = scheduledEvent(at: due, hours: 24)
        schedule.announcedAt = try resetStatusDate("2026-09-25T15:00:00Z")
        schedule.scope = RateLimitResetTodayScope(plans: ["plus"], windows: ["weekly"])
        let now = due.addingTimeInterval(5 * 3_600)

        var tooEarly = completedEvent(
            at: try resetStatusDate("2026-09-25T06:59:59Z"),
            postID: "2")
        tooEarly.announcedAt = try resetStatusDate("2026-09-25T16:00:00Z")
        tooEarly.scope = schedule.scope
        #expect(makeSnapshot(
            now: now,
            events: [tooEarly],
            graceSchedules: [schedule]).verdictPresentation(
                now: now,
                calendar: resetStatusUTCCalendar).reason == .grace)

        var matching = tooEarly
        matching.effectiveAt = try resetStatusDate("2026-09-25T07:00:00Z")
        #expect(makeSnapshot(
            now: now,
            events: [matching],
            graceSchedules: [schedule]).verdictPresentation(
                now: now,
                calendar: resetStatusUTCCalendar).reason == .none)

        var announcedTooSoon = matching
        announcedTooSoon.announcedAt = schedule.announcedAt.addingTimeInterval(-1)
        #expect(makeSnapshot(
            now: now,
            events: [announcedTooSoon],
            graceSchedules: [schedule]).verdictPresentation(
                now: now,
                calendar: resetStatusUTCCalendar).reason == .grace)

        var wrongType = matching
        wrongType.resetType = .banked
        #expect(makeSnapshot(
            now: now,
            events: [wrongType],
            graceSchedules: [schedule]).verdictPresentation(
                now: now,
                calendar: resetStatusUTCCalendar).reason == .grace)

        var wrongScope = matching
        wrongScope.scope = RateLimitResetTodayScope(plans: ["enterprise"], windows: ["weekly"])
        #expect(makeSnapshot(
            now: now,
            events: [wrongScope],
            graceSchedules: [schedule]).verdictPresentation(
                now: now,
                calendar: resetStatusUTCCalendar).reason == .grace)
    }

    @Test("manual completion is scope-agnostic when excluding grace")
    func manualCompletionUsesWildcardScope() throws {
        let due = try resetStatusDate("2026-09-25T20:00:00Z")
        var schedule = scheduledEvent(at: due, hours: 24)
        schedule.scope = RateLimitResetTodayScope(plans: ["plus"], windows: ["weekly"])
        var reference = scheduledEvent(at: due, hours: 3, postID: "9")
        reference.scope = RateLimitResetTodayScope(plans: ["enterprise"], windows: ["five_hour"])
        let manual = RateLimitResetManualCompletion(
            id: "manual:1",
            completedAt: due.addingTimeInterval(60),
            visibleUntil: due.addingTimeInterval(10 * 3_600),
            representativePostID: "9",
            schedulePostIDs: ["9"],
            schedules: [reference])
        let now = due.addingTimeInterval(5 * 3_600)
        let snapshot = makeSnapshot(
            now: now,
            graceSchedules: [schedule],
            timeline: RateLimitResetTimeline(manualCompletions: [manual]))

        #expect(snapshot.verdictPresentation(
            now: now,
            calendar: resetStatusUTCCalendar).reason == .none)
    }

    private func scheduledFixture(hoursJSON: String?) -> ResetStatusEventFixture {
        ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-09-24T12:00:00Z",
            effectiveAt: "2026-09-25T07:00:00Z",
            schedulePrecision: "date",
            scheduleBasis: "explicit",
            scheduleGraceHoursJSON: hoursJSON)
    }

    private func scheduledEvent(
        at: Date,
        hours: Double,
        resetType: RateLimitResetType = .global,
        postID: String = "1") -> RateLimitResetTodayEvent
    {
        RateLimitResetTodayEvent(
            kind: .resetScheduled,
            resetType: resetType,
            announcedAt: at.addingTimeInterval(-3_600),
            effectiveAt: at,
            schedulePrecision: .datetime,
            scheduleBasis: .explicit,
            scheduleGraceHours: hours,
            scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
            source: RateLimitResetTodaySource(postID: postID),
            confidence: 0.9,
            rationale: resetType == .banked
                ? "Explicit Codex reset-bank credit schedule."
                : "Explicit Codex quota reset schedule.",
            text: "Scheduled reset.")
    }

    private func completedEvent(at: Date, postID: String) -> RateLimitResetTodayEvent {
        RateLimitResetTodayEvent(
            kind: .resetCompleted,
            announcedAt: at,
            effectiveAt: at,
            scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
            source: RateLimitResetTodaySource(postID: postID),
            confidence: 0.98,
            rationale: "Explicit Codex quota reset announcement.",
            text: "Reset completed.")
    }

    private func makeSnapshot(
        now: Date,
        events: [RateLimitResetTodayEvent] = [],
        graceSchedules: [RateLimitResetTodayEvent],
        timeline: RateLimitResetTimeline? = nil) -> RateLimitResetTodaySnapshot
    {
        RateLimitResetTodaySnapshot(
            response: RateLimitResetTodayResponse(
                schemaVersion: 1,
                generatedAt: now,
                lastSuccessfulCheckAt: now,
                monitor: RateLimitResetTodayMonitor(status: .ok),
                events: events,
                graceSchedules: graceSchedules,
                resetTimeline: timeline),
            now: now,
            calendar: resetStatusUTCCalendar)
    }
}
