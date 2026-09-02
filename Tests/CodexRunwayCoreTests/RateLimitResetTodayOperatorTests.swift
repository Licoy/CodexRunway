import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Rate limit reset operator events")
struct RateLimitResetTodayOperatorTests {
    private let operatorPostID = "op_4c549b7d3147b644968bb73a"

    @Test("decodes operator-confirmed resets without an X source")
    func decodesOperatorConfirmedReset() throws {
        let now = try resetStatusDate("2026-08-25T16:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            event: operatorEvent(announcedAt: "2026-08-25T14:30:00Z"),
            now: now)
            .checked(at: "2026-08-25T16:00:00Z")
            .decode()
        let event = try #require(snapshot.events.first)
        let occurredAt = try resetStatusDate("2026-08-25T14:30:00Z")

        #expect(event.source.origin == .operator)
        #expect(event.source.isOperator)
        #expect(event.source.handle == nil)
        #expect(event.source.url == nil)
        #expect(event.source.postID == operatorPostID)
        #expect(event.kind == .resetCompleted)
        #expect(event.resetType == .global)
        #expect(snapshot.resolvedState(now: now, calendar: resetStatusUTCCalendar) == .yes)
        #expect(snapshot.latestReset(now: now)?.at == occurredAt)
        #expect(snapshot.latestReset(now: now)?.resetType == .global)
        #expect(
            snapshot.evidenceLine(
                l10n: L10n(language: .simplifiedChinese),
                now: now,
                calendar: resetStatusUTCCalendar)
                == "运营确认已重置，Tibo 未发 X。")
        #expect(
            snapshot.evidenceURL(now: now, calendar: resetStatusUTCCalendar)?.absoluteString
                == "https://www.codexrunway.com/history/1787668200000.html")
    }

    @Test("infers operator origin from an op_ event id")
    func infersOperatorOriginFromEventID() throws {
        let now = try resetStatusDate("2026-08-25T16:00:00Z")
        var event = operatorEvent(announcedAt: "2026-08-25T14:30:00Z")
        event.omitOrigin = true
        let snapshot = try ResetStatusFeedFixture(event: event, now: now)
            .checked(at: "2026-08-25T16:00:00Z")
            .decode()

        #expect(snapshot.events.first?.source.origin == .operator)
        #expect(snapshot.events.first?.source.postID == operatorPostID)
    }

    @Test("operator completion is the latest reset over older X posts")
    func operatorCompletionOutranksOlderXReset() throws {
        let now = try resetStatusDate("2026-08-25T16:00:00Z")
        let older = ResetStatusEventFixture(
            kind: "reset_completed",
            announcedAt: "2026-08-24T00:46:51Z",
            postID: "2091688655828246890")
        let operatorReset = operatorEvent(announcedAt: "2026-08-25T14:30:00Z")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: "\(operatorReset.json),\n\(older.json)",
            now: now)
            .checked(at: "2026-08-25T16:00:00Z")
            .decode()
        let occurredAt = try resetStatusDate("2026-08-25T14:30:00Z")

        #expect(snapshot.latestReset(now: now)?.at == occurredAt)
        #expect(snapshot.latestReset(now: now)?.resetType == .global)
        #expect(snapshot.events.contains { $0.source.isOperator })
    }

    @Test("rejects operator sources that still carry an X handle or URL")
    func rejectsOperatorSourceWithXFields() throws {
        let now = try resetStatusDate("2026-08-25T16:00:00Z")
        var withHandle = operatorEvent(announcedAt: "2026-08-25T14:30:00Z")
        withHandle.handle = "thsottiaux"
        var withURL = operatorEvent(announcedAt: "2026-08-25T14:30:00Z")
        withURL.includeURL = true

        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(event: withHandle, now: now).decode()
        }
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(event: withURL, now: now).decode()
        }
    }

    @Test("rejects operator events that are not completed or scheduled resets")
    func rejectsUnsupportedOperatorEventKinds() throws {
        let now = try resetStatusDate("2026-08-25T16:00:00Z")
        let uncertain = ResetStatusEventFixture(
            kind: "uncertain",
            announcedAt: "2026-08-25T14:00:00Z",
            postID: operatorPostID,
            origin: "operator",
            handle: nil,
            includeURL: false)
        let banked = ResetStatusEventFixture(
            kind: "banked_reset",
            announcedAt: "2026-08-25T14:00:00Z",
            postID: operatorPostID,
            origin: "operator",
            handle: nil,
            includeURL: false)

        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(event: uncertain, now: now).decode()
        }
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(event: banked, now: now).decode()
        }
    }

    @Test("no-state copy includes last reset type and a single-unit ago")
    func noneHintIncludesLastResetTypeAndAgo() throws {
        let now = try resetStatusDate("2026-08-26T00:30:00Z")
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let snapshot = try ResetStatusFeedFixture(
            event: operatorEvent(announcedAt: "2026-08-25T14:30:00Z"),
            now: now)
            .checked(at: "2026-08-26T00:30:00Z")
            .using(shanghai)
            .decode()
        let l10n = L10n(language: .simplifiedChinese)
        let hint = try #require(snapshot.noneHintLastReset(l10n: l10n, now: now))

        #expect(snapshot.resolvedState(now: now, calendar: shanghai) == .no)
        #expect(hint.resetType == .global)
        #expect(hint.ago == "10小时")
        #expect(hint.text == "今日暂无已完成或已排期的重置，上次发生全局重置为10小时之前")
        #expect(
            RateLimitResetNoneHint.segments(l10n.text(.rateLimitResetTodayNoHintWithLast))
                == [
                    .text("今日暂无已完成或已排期的重置，上次发生"),
                    .resetType,
                    .text("为"),
                    .ago,
                    .text("之前"),
                ])
    }

    @Test("accepts an operator completionPostId on fulfilled schedules")
    func acceptsOperatorCompletionPostID() throws {
        let now = try resetStatusDate("2026-08-25T16:00:00Z")
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-08-24T12:00:00Z",
            effectiveAt: "2026-08-25T14:00:00Z",
            schedulePrecision: "datetime",
            postID: "2091688655828246890")
        let operatorReset = operatorEvent(announcedAt: "2026-08-25T14:30:00Z")
        let timeline = """
        {
          "nextSchedule": null,
          "recentNonCompletedPostId": null,
          "fulfilledSchedules": [
            {
              "schedule": \(scheduled.json),
              "window": {
                "startAt": "2026-08-25T14:00:00.000Z",
                "endAt": "2026-08-25T14:00:00.000Z",
                "precision": "datetime"
              },
              "completionPostId": "\(operatorPostID)",
              "completedAt": "2026-08-25T14:30:00.000Z",
              "visibleUntil": "2026-09-04T14:30:00.000Z"
            }
          ]
        }
        """
        let snapshot = try ResetStatusFeedFixture(event: operatorReset, now: now)
            .checked(at: "2026-08-25T16:00:00Z")
            .withTimeline(timeline)
            .decode()

        #expect(snapshot.resetTimeline?.fulfilledSchedules.first?.completionPostID == operatorPostID)
        #expect(snapshot.resolvedState(now: now, calendar: resetStatusUTCCalendar) == .yes)
    }

    @Test("expired operator schedule with empty nextSchedule is no, not unknown")
    func expiredOperatorScheduleIsUnconfirmedNo() throws {
        let now = try resetStatusDate("2026-09-02T13:48:03Z")
        let scheduledID = "op_77973cda8bc5d0be9afde39e"
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            resetType: "global",
            announcedAt: "2026-09-01T00:12:30Z",
            effectiveAt: "2026-09-01T14:00:00Z",
            schedulePrecision: "date",
            scheduleBasis: "explicit",
            postID: scheduledID,
            origin: "operator",
            handle: nil,
            includeURL: false)
        let completed = ResetStatusEventFixture(
            kind: "reset_completed",
            announcedAt: "2026-08-31T02:34:27Z",
            postID: "2094252447271366730")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: "\(scheduled.json),\n\(completed.json)",
            now: now)
            .checked(at: "2026-09-02T13:48:03Z")
            .using(resetStatusUTCCalendar)
            .withTimeline(
                resetStatusEmptyTimelineJSON(recentNonCompletedPostId: scheduledID))
            .decode()
        let l10n = L10n(language: .simplifiedChinese)
        let hint = try #require(
            snapshot.unconfirmedScheduleHint(
                l10n: l10n,
                now: now,
                calendar: resetStatusUTCCalendar))

        #expect(snapshot.resolvedState(now: now, calendar: resetStatusUTCCalendar) == .no)
        #expect(snapshot.nextScheduledReset(now: now) == nil)
        #expect(
            snapshot.primaryEvidenceEvent(now: now, calendar: resetStatusUTCCalendar)?.source.postID
                == scheduledID)
        #expect(
            snapshot.evidenceLine(
                l10n: l10n,
                now: now,
                calendar: resetStatusUTCCalendar)
                == "运营确认已排期重置，Tibo 未发 X。")
        #expect(hint.resetType == .global)
        #expect(hint.text == "已排期的全局重置时间已过，但未得到确认")
        #expect(
            snapshot.unconfirmedScheduleHint(
                l10n: L10n(language: .english),
                now: now,
                calendar: resetStatusUTCCalendar)?.text
                == "The scheduled Global reset time passed without confirmation")
    }

    @Test("pending operator schedule on nextSchedule is yes")
    func pendingOperatorScheduleIsYes() throws {
        let now = try resetStatusDate("2026-09-01T08:00:00Z")
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            resetType: "global",
            announcedAt: "2026-09-01T00:12:30Z",
            effectiveAt: "2026-09-01T18:00:00Z",
            schedulePrecision: "datetime",
            scheduleBasis: "explicit",
            postID: operatorPostID,
            origin: "operator",
            handle: nil,
            includeURL: false)
        let snapshot = try ResetStatusFeedFixture(event: scheduled, now: now)
            .checked(at: "2026-09-01T08:00:00Z")
            .using(resetStatusUTCCalendar)
            .withTimeline(
                resetStatusEmptyTimelineJSON(
                    nextScheduleJSON: scheduled.json,
                    recentNonCompletedPostId: operatorPostID))
            .decode()

        #expect(snapshot.resolvedState(now: now, calendar: resetStatusUTCCalendar) == .yes)
        #expect(snapshot.nextScheduledReset(now: now)?.event.source.postID == operatorPostID)
        #expect(snapshot.unconfirmedExpiredSchedule(now: now, calendar: resetStatusUTCCalendar) == nil)
        #expect(
            snapshot.evidenceLine(
                l10n: L10n(language: .simplifiedChinese),
                now: now,
                calendar: resetStatusUTCCalendar)
                == "运营确认已排期重置，Tibo 未发 X。")
    }

    @Test("rejects a non-event recentNonCompletedPostId")
    func rejectsInvalidRecentNonCompletedPostID() throws {
        let now = try resetStatusDate("2026-09-02T13:48:03Z")
        let completed = ResetStatusEventFixture(
            kind: "reset_completed",
            announcedAt: "2026-08-31T02:34:27Z")

        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(event: completed, now: now)
                .withTimeline(resetStatusEmptyTimelineJSON(recentNonCompletedPostId: "not-an-id"))
                .decode()
        }
    }

    private func operatorEvent(
        announcedAt: String,
        resetType: String = "global") -> ResetStatusEventFixture
    {
        ResetStatusEventFixture(
            kind: "reset_completed",
            resetType: resetType,
            announcedAt: announcedAt,
            effectiveAt: announcedAt,
            postID: operatorPostID,
            origin: "operator",
            handle: nil,
            includeURL: false)
    }
}
