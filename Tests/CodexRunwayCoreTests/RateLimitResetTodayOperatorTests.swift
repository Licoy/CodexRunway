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

    @Test("rejects operator events that are not completed resets")
    func rejectsNonCompletedOperatorEvents() throws {
        let now = try resetStatusDate("2026-08-25T16:00:00Z")
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-08-25T14:00:00Z",
            effectiveAt: "2026-08-26T14:00:00Z",
            postID: operatorPostID,
            origin: "operator",
            handle: nil,
            includeURL: false)

        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(event: scheduled, now: now).decode()
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
