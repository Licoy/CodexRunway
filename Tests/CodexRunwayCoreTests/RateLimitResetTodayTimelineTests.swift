import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Rate limit reset today timeline")
struct RateLimitResetTodayTimelineTests {
    @Test("same-day manual completion is yes without an X completion event")
    func sameDayManualCompletionIsYes() throws {
        let now = try resetStatusDate("2026-08-13T10:29:13Z")
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-08-13T01:01:37Z",
            effectiveAt: "2026-08-13T02:01:37Z",
            schedulePrecision: "datetime",
            scheduleBasis: "explicit",
            postID: "2087706104814023111")
        let snapshot = try ResetStatusFeedFixture(
            event: .init(kind: "reset_completed", announcedAt: "2026-08-11T00:27:44Z"),
            now: now)
            .checked(at: "2026-08-13T10:29:13Z")
            .withTimeline(
                resetStatusEmptyTimelineJSON(
                    manualJSON: """
                    {
                      "id": "manual:cl_abd57edf90eb450aa54bd48c010854af",
                      "completedAt": "2026-08-13T04:35:00.000Z",
                      "visibleUntil": "2026-08-23T04:35:00.000Z",
                      "representativePostId": "2087706104814023111",
                      "schedulePostIds": ["2087706104814023111"],
                      "schedules": [\(scheduled.json)],
                      "fulfillmentOrigin": "manual"
                    }
                    """,
                    suppressedJSON: "\"2087706104814023111\""))
            .decode()

        #expect(snapshot.hasResetTimeline)
        #expect(snapshot.resolvedState(now: now, calendar: resetStatusUTCCalendar) == .yes)
        let completedAt = try resetStatusDate("2026-08-13T04:35:00Z")
        #expect(snapshot.hasAlreadyEffectiveResetToday(now: now, calendar: resetStatusUTCCalendar))
        #expect(snapshot.nextScheduledReset(now: now) == nil)
        #expect(snapshot.latestResetAt(now: now) == completedAt)
        #expect(snapshot.primaryEvidenceEvent(now: now, calendar: resetStatusUTCCalendar)?
            .source.postID == "2087706104814023111")
        #expect(
            snapshot.evidenceLine(
                l10n: L10n(language: .english),
                now: now,
                calendar: resetStatusUTCCalendar)
                == "Confirmed without an X completion post.")
        #expect(
            snapshot.evidenceLine(
                l10n: L10n(language: .simplifiedChinese),
                now: now,
                calendar: resetStatusUTCCalendar)
                == "已确认发生重置，但没有对应的 X 完成帖。")
    }

    @Test("resetTimeline nextSchedule is authoritative over leftover event schedules")
    func timelineNextScheduleIsAuthoritative() throws {
        let now = try resetStatusDate("2026-08-01T12:00:00Z")
        let leftover = ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-08-01T08:00:00Z",
            effectiveAt: "2026-08-02T12:00:00Z",
            postID: "2086189414292865249")
        let snapshot = try ResetStatusFeedFixture(event: leftover, now: now)
            .checked(at: "2026-08-01T12:00:00Z")
            .withTimeline(
                resetStatusEmptyTimelineJSON(
                    suppressedJSON: "\"2086189414292865249\""))
            .decode()

        #expect(snapshot.hasResetTimeline)
        #expect(snapshot.resolvedState(now: now) == .no)
        #expect(snapshot.nextScheduledReset(now: now) == nil)
        #expect(snapshot.primaryEvidenceEvent(now: now) == nil)
        #expect(snapshot.evidenceURL(now: now) == nil)
    }

    @Test("timeline-aware completion wins over an independent same-day schedule")
    func timelineAwareCompletionWinsOverSameDaySchedule() throws {
        let now = try resetStatusDate("2026-08-01T12:00:00Z")
        let completed = ResetStatusEventFixture(
            kind: "reset_completed",
            announcedAt: "2026-08-01T11:50:00Z",
            postID: "100")
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-08-01T08:00:00Z",
            effectiveAt: "2026-08-01T14:30:00Z",
            schedulePrecision: "datetime",
            postID: "200")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: "\(completed.json),\n\(scheduled.json)",
            now: now)
            .checked(at: "2026-08-01T12:00:00Z")
            .withTimeline(
                resetStatusEmptyTimelineJSON(
                    nextScheduleJSON: scheduled.json,
                    recentNonCompletedPostId: "200"))
            .using(resetStatusUTCCalendar)
            .decode()

        #expect(snapshot.resolvedState(now: now, calendar: resetStatusUTCCalendar) == .yes)
        #expect(snapshot.hasAlreadyEffectiveResetToday(now: now, calendar: resetStatusUTCCalendar))
        #expect(snapshot.prefersSameDayScheduleExplanation(now: now, calendar: resetStatusUTCCalendar) == false)
        #expect(snapshot.primaryEvidenceEvent(now: now, calendar: resetStatusUTCCalendar)?.source.postID == "100")
        #expect(snapshot.nextScheduledReset(now: now)?.event.source.postID == "200")
    }

    @Test("explicit datetime at Tibo midnight stays a single instant")
    func explicitDatetimeAtMidnightStaysAPoint() throws {
        let now = try resetStatusDate("2026-08-10T06:59:59Z")
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-08-09T12:00:00Z",
            effectiveAt: "2026-08-10T07:00:00Z",
            schedulePrecision: "datetime",
            postID: "2087706104814023111")
        let snapshot = try ResetStatusFeedFixture(event: scheduled, now: now)
            .checked(at: "2026-08-10T06:59:59Z")
            .withTimeline(
                resetStatusEmptyTimelineJSON(
                    nextScheduleJSON: scheduled.json,
                    recentNonCompletedPostId: "2087706104814023111"))
            .decode()

        let next = try #require(snapshot.nextScheduledReset(now: now))
        let midnight = try resetStatusDate("2026-08-10T07:00:00Z")
        #expect(next.isRange == false)
        #expect(next.effectiveAt == midnight)
        #expect(next.effectiveUntil == next.effectiveAt)
        #expect(snapshot.nextScheduledReset(now: midnight) == nil)
    }

    @Test("date precision expands even when the clock is not midnight")
    func datePrecisionExpandsWithoutMidnightHeuristic() throws {
        let now = try resetStatusDate("2026-08-10T12:00:00Z")
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-08-09T12:00:00Z",
            effectiveAt: "2026-08-10T15:00:00Z",
            schedulePrecision: "date",
            postID: "200")
        let snapshot = try ResetStatusFeedFixture(event: scheduled, now: now)
            .checked(at: "2026-08-10T12:00:00Z")
            .withTimeline(
                resetStatusEmptyTimelineJSON(
                    nextScheduleJSON: scheduled.json,
                    recentNonCompletedPostId: "200"))
            .decode()

        let next = try #require(snapshot.nextScheduledReset(now: now))
        let expectedStart = try resetStatusDate("2026-08-10T15:00:00Z")
        let expectedEnd = try resetStatusDate("2026-08-11T14:59:00Z")
        #expect(next.isRange)
        #expect(next.effectiveAt == expectedStart)
        #expect(next.effectiveUntil == expectedEnd)
    }

    @Test("date-only window stays pending until the next Tibo midnight")
    func dateOnlyWindowStaysPendingUntilNextMidnight() throws {
        let now = try resetStatusDate("2026-08-11T06:59:30Z")
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-08-09T12:00:00Z",
            effectiveAt: "2026-08-10T07:00:00Z",
            schedulePrecision: "date",
            postID: "200")
        let snapshot = try ResetStatusFeedFixture(event: scheduled, now: now)
            .checked(at: "2026-08-11T06:59:30Z")
            .withTimeline(
                resetStatusEmptyTimelineJSON(
                    nextScheduleJSON: scheduled.json,
                    recentNonCompletedPostId: "200"))
            .decode()

        let expiredAt = try resetStatusDate("2026-08-11T07:00:00Z")
        #expect(snapshot.nextScheduledReset(now: now)?.event.source.postID == "200")
        #expect(snapshot.nextScheduledReset(now: expiredAt) == nil)
    }

    @Test("contextual inference schedule is accepted and uses preview copy")
    func contextualInferenceScheduleUsesPreviewCopy() throws {
        let now = try resetStatusDate("2026-08-10T20:00:00Z")
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let snapshot = try ResetStatusFeedFixture(
            event: .init(
                kind: "reset_scheduled",
                announcedAt: "2026-08-09T12:00:00Z",
                effectiveAt: "2026-08-10T07:00:00Z",
                schedulePrecision: "date",
                scheduleBasis: "contextual_inference"),
            now: now)
            .checked(at: "2026-08-10T20:00:00Z")
            .using(losAngeles)
            .decode()

        #expect(snapshot.resolvedState(now: now, calendar: losAngeles) == .yes)
        #expect(snapshot.events.first?.scheduleBasis == .contextualInference)
        #expect(
            snapshot.evidenceLine(l10n: L10n(language: .english), now: now, calendar: losAngeles)
                == "A high-probability Codex quota reset was inferred from context.")
        #expect(
            snapshot.evidenceLine(l10n: L10n(language: .simplifiedChinese), now: now, calendar: losAngeles)
                == "根据上下文推断出高概率的 Codex 配额重置预告。")
    }

    @Test("manual completion fires a newly detected reset alert")
    func manualCompletionFiresDetectedAlert() throws {
        let now = try resetStatusDate("2026-08-13T10:29:13Z")
        let previous = try ResetStatusFeedFixture(now: now)
            .checked(at: "2026-08-13T10:29:13Z")
            .withTimeline(resetStatusEmptyTimelineJSON())
            .decode()
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-08-13T01:01:37Z",
            effectiveAt: "2026-08-13T02:01:37Z",
            schedulePrecision: "datetime",
            postID: "2087706104814023111")
        let current = try ResetStatusFeedFixture(now: now)
            .checked(at: "2026-08-13T10:29:13Z")
            .withTimeline(
                resetStatusEmptyTimelineJSON(
                    manualJSON: """
                    {
                      "id": "manual:cl_test",
                      "completedAt": "2026-08-13T04:35:00.000Z",
                      "visibleUntil": "2026-08-23T04:35:00.000Z",
                      "representativePostId": "2087706104814023111",
                      "schedulePostIds": ["2087706104814023111"],
                      "schedules": [\(scheduled.json)],
                      "fulfillmentOrigin": "manual"
                    }
                    """))
            .decode()

        let alerts = RunwayAlertDecider.rateLimitResetTodayAlerts(
            previous: previous,
            current: current,
            now: now,
            calendar: resetStatusUTCCalendar)
        #expect(alerts.count == 1)
        let completedAt = try resetStatusDate("2026-08-13T04:35:00Z")
        #expect(alerts[0].kind == .rateLimitResetDetected)
        #expect(alerts[0].name == "2087706104814023111")
        #expect(alerts[0].date == completedAt)
    }

    @Test("heatmap and extra timeline fields do not break decoding")
    func extraOfficialFieldsDoNotBreakDecoding() throws {
        let now = try resetStatusDate("2026-08-13T10:29:13Z")
        let data = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-08-13T10:29:13.809Z",
          "lastSuccessfulCheckAt": "2026-08-13T10:29:13.809Z",
          "monitor": {"status": "ok", "errorCode": null},
          "events": [
            {
              "kind": "reset_completed",
              "resetType": "global",
              "announcedAt": "2026-08-11T00:27:44.000Z",
              "effectiveAt": null,
              "scope": {"plans": ["all"], "windows": ["unknown"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "2086972802457063486",
                "url": "https://x.com/thsottiaux/status/2086972802457063486"
              },
              "confidence": 0.97,
              "rationale": "Explicit Codex quota reset announcement.",
              "text": "Hi.\\n\\nIt is done."
            }
          ],
          "heatmap": {
            "timezone": "UTC",
            "weeks": 53,
            "total": 1,
            "days": [
              {
                "date": "2026-08-13",
                "count": 1,
                "level": 1,
                "sources": [
                  {
                    "postId": "2087706104814023111",
                    "kind": "reset_completed",
                    "resetType": "banked",
                    "announcedAt": "2026-08-13T04:35:00.000Z",
                    "effectiveAt": "2026-08-13T04:35:00.000Z",
                    "url": "https://x.com/thsottiaux/status/2087706104814023111",
                    "text": "Enjoy a nice reset everyone."
                  }
                ]
              }
            ]
          },
          "resetTimeline": {
            "nextSchedule": null,
            "recentNonCompletedPostId": null,
            "fulfilledSchedules": [
              {
                "schedule": {
                  "kind": "reset_scheduled",
                  "resetType": "global",
                  "announcedAt": "2026-08-08T20:34:50.000Z",
                  "effectiveAt": "2026-08-10T07:00:00.000Z",
                  "schedulePrecision": "date",
                  "scope": {"plans": ["all"], "windows": ["weekly"]},
                  "source": {
                    "handle": "thsottiaux",
                    "postId": "2086189414292865249",
                    "url": "https://x.com/thsottiaux/status/2086189414292865249"
                  },
                  "confidence": 0.92,
                  "rationale": "Explicit Codex quota reset schedule.",
                  "text": "I'll do another performative reset on Monday"
                },
                "window": {
                  "startAt": "2026-08-10T07:00:00.000Z",
                  "endAt": "2026-08-11T07:00:00.000Z",
                  "precision": "date"
                },
                "completionPostId": "2086972802457063486",
                "completedAt": "2026-08-11T00:27:44.000Z",
                "visibleUntil": "2026-08-21T00:27:44.000Z"
              }
            ],
            "fulfilledBanked": [
              {
                "banked": {
                  "kind": "banked_reset",
                  "resetType": "banked",
                  "announcedAt": "2026-08-11T00:20:00.000Z",
                  "effectiveAt": null,
                  "scope": {"plans": ["all"], "windows": ["unknown"]},
                  "source": {
                    "handle": "thsottiaux",
                    "postId": "2086972802457063400",
                    "url": "https://x.com/thsottiaux/status/2086972802457063400"
                  },
                  "confidence": 0.97,
                  "rationale": "Banked reset announcement; not a completed reset.",
                  "text": "A reset-bank credit will be available."
                },
                "completionPostId": "2086972802457063486",
                "completedAt": "2026-08-11T00:27:44.000Z",
                "visibleUntil": "2026-08-21T00:27:44.000Z"
              }
            ],
            "manualCompletions": [
              {
                "id": "manual:cl_abd57edf90eb450aa54bd48c010854af",
                "completedAt": "2026-08-13T04:35:00.000Z",
                "visibleUntil": "2026-08-23T04:35:00.000Z",
                "representativePostId": "2087706104814023111",
                "schedulePostIds": ["2087706104814023111"],
                "schedules": [
                  {
                    "kind": "reset_scheduled",
                    "resetType": "global",
                    "announcedAt": "2026-08-13T01:01:37.000Z",
                    "effectiveAt": "2026-08-13T02:01:37.000Z",
                    "schedulePrecision": "datetime",
                    "scheduleBasis": "explicit",
                    "scope": {"plans": ["all"], "windows": ["unknown"]},
                    "source": {
                      "handle": "thsottiaux",
                      "postId": "2087706104814023111",
                      "url": "https://x.com/thsottiaux/status/2087706104814023111"
                    },
                    "confidence": 0.97,
                    "rationale": "Explicit Codex quota reset schedule.",
                    "text": "Enjoy a nice reset everyone. Landing in the next hour or so."
                  }
                ],
                "fulfillmentOrigin": "manual"
              }
            ],
            "suppressedPostIds": ["2086189414292865249", "2087706104814023111"]
          }
        }
        """.data(using: .utf8)!

        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let snapshot = try RateLimitResetTodaySnapshot.decode(from: data, now: now, calendar: shanghai)

        #expect(snapshot.hasResetTimeline)
        #expect(snapshot.resetTimeline?.fulfilledSchedules.count == 1)
        #expect(snapshot.resetTimeline?.fulfilledSchedules.first?.schedule.resetType == .global)
        #expect(snapshot.resetTimeline?.fulfilledBanked.count == 1)
        #expect(snapshot.resetTimeline?.fulfilledBanked.first?.banked.kind == .bankedReset)
        #expect(snapshot.resetTimeline?.fulfilledBanked.first?.banked.resetType == .banked)
        #expect(snapshot.resetTimeline?.manualCompletions.count == 1)
        #expect(snapshot.resetTimeline?.manualCompletions.first?.schedules.first?.resetType == .global)
        let completedAt = try resetStatusDate("2026-08-13T04:35:00Z")
        #expect(snapshot.resetTimeline?.suppressedPostIds.count == 2)
        #expect(snapshot.resolvedState(now: now, calendar: shanghai) == .yes)
        #expect(snapshot.latestResetAt(now: now) == completedAt)
    }

    @Test("rejects contextual rationale unless the schedule basis matches")
    func rejectsMismatchedContextualRationale() throws {
        let now = try resetStatusDate("2026-08-10T12:00:00Z")
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(
                eventsJSON: """
                {
                  "kind": "reset_scheduled",
                  "announcedAt": "2026-08-09T12:00:00Z",
                  "effectiveAt": "2026-08-10T15:00:00Z",
                  "schedulePrecision": "datetime",
                  "scope": {"plans": ["all"], "windows": ["weekly"]},
                  "source": {
                    "handle": "thsottiaux",
                    "postId": "123",
                    "url": "https://x.com/thsottiaux/status/123"
                  },
                  "confidence": 0.9,
                  "rationale": "High-probability Codex quota reset preview inferred from context.",
                  "text": "Maybe tomorrow."
                }
                """,
                now: now)
                .decode()
        }
    }
}
