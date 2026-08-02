import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Rate limit reset today")
struct RateLimitResetTodayTests {
    @Test("uses the Codex Runway status endpoints")
    func usesCodexRunwayStatusEndpoints() {
        #expect(RateLimitResetTodayClient.siteURL.absoluteString == "https://www.codexrunway.com/")
        #expect(
            RateLimitResetTodayClient.statusURL.absoluteString
                == "https://www.codexrunway.com/api/status.json")
    }

    @Test("notifies when a reset becomes newly detected and when schedule is near")
    func rateLimitResetTodayAlerts() throws {
        let now = try resetStatusDate("2026-07-29T12:00:00Z")
        let previousNo = try ResetStatusFeedFixture(eventsJSON: "", now: now).decode()
        let currentYes = try ResetStatusFeedFixture(
            event: .init(kind: "reset_completed", announcedAt: "2026-07-29T04:09:02Z"),
            now: now)
            .decode()
        let detected = RunwayAlertDecider.rateLimitResetTodayAlerts(
            previous: previousNo,
            current: currentYes,
            now: now)
        #expect(detected.count == 1)
        #expect(detected[0].kind == .rateLimitResetDetected)

        // First load with no previous snapshot should not spam.
        #expect(
            RunwayAlertDecider.rateLimitResetTodayAlerts(
                previous: nil,
                current: currentYes,
                now: now)
                .isEmpty)

        let withSchedule = try ResetStatusFeedFixture(
            eventsJSON: """
            {
              "kind": "reset_scheduled",
              "announcedAt": "2026-07-29T05:44:16.000Z",
              "effectiveAt": "2026-07-29T12:25:00.000Z",
              "scope": {"plans": ["all"], "windows": ["weekly"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "999",
                "url": "https://x.com/thsottiaux/status/999"
              },
              "confidence": 0.9,
              "rationale": "Explicit Codex quota reset schedule.",
              "text": "Scheduled reset later today."
            }
            """,
            now: now)
            .decode()
        let upcoming30 = RunwayAlertDecider.rateLimitResetTodayAlerts(
            previous: withSchedule,
            current: withSchedule,
            now: now)
        #expect(upcoming30.count == 1)
        #expect(upcoming30[0].kind == .rateLimitResetUpcoming)
        #expect(upcoming30[0].threshold == 30)

        // 12:25 - 11:35 = 50 minutes → 1-hour threshold.
        let hourOut = try resetStatusDate("2026-07-29T11:35:00Z")
        let upcoming60 = RunwayAlertDecider.rateLimitResetTodayAlerts(
            previous: withSchedule,
            current: withSchedule,
            now: hourOut)
        #expect(upcoming60.count == 1)
        #expect(upcoming60[0].threshold == 60)
    }

    @Test("primary evidence and next schedule prefer actionable events")
    func primaryEvidenceAndNextSchedulePreferActionableEvents() throws {
        let now = try resetStatusDate("2026-07-29T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: """
            {
              "kind": "reset_scheduled",
              "announcedAt": "2026-07-29T05:44:16.000Z",
              "effectiveAt": "2026-07-31T12:00:00.000Z",
              "scope": {"plans": ["all"], "windows": ["unknown"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "2082341416681001277",
                "url": "https://x.com/thsottiaux/status/2082341416681001277"
              },
              "confidence": 0.85,
              "rationale": "Explicit Codex quota reset schedule.",
              "text": "Reset scheduled for Friday."
            },
            {
              "kind": "reset_completed",
              "announcedAt": "2026-07-29T04:09:02.000Z",
              "effectiveAt": null,
              "scope": {"plans": ["all"], "windows": ["weekly"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "2082317452755751098",
                "url": "https://x.com/thsottiaux/status/2082317452755751098"
              },
              "confidence": 0.95,
              "rationale": "Explicit Codex quota reset announcement.",
              "text": "Usage limits have been reset."
            }
            """,
            now: now)
            .decode()

        #expect(snapshot.state == .yes)
        #expect(snapshot.primaryEvidenceEvent(now: now)?.source.postID == "2082317452755751098")
        #expect(snapshot.nextScheduledReset(now: now)?.event.source.postID == "2082341416681001277")
        #expect(
            snapshot.evidenceURL(now: now)?.absoluteString.contains("2082317452755751098") == true)
    }

    @Test("decodes the complete API v1 event")
    func decodesCompleteAPIV1Event() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: """
            {
              "kind": "reset_completed",
              "announcedAt": "2026-07-28T11:55:00.000Z",
              "effectiveAt": null,
              "scope": {
                "plans": ["all"],
                "windows": ["weekly", "five_hour"]
              },
              "source": {
                "handle": "thsottiaux",
                "postId": "123",
                "url": "https://x.com/thsottiaux/status/123"
              },
              "confidence": 0.98,
              "rationale": "Explicit Codex quota reset announcement.",
              "text": "I have reset usage limits for Codex."
            }
            """,
            now: now)
            .decode()
        let expectedAnnouncedAt = try resetStatusDate("2026-07-28T11:55:00Z")

        let event = try #require(snapshot.events.first)
        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.generatedAt == now)
        #expect(snapshot.lastSuccessfulCheckAt == now)
        #expect(snapshot.monitor.status == .ok)
        #expect(snapshot.monitor.errorCode == nil)
        #expect(event.kind == .resetCompleted)
        #expect(event.announcedAt == expectedAnnouncedAt)
        #expect(event.effectiveAt == nil)
        #expect(event.scope.plans == ["all"])
        #expect(event.scope.windows == ["weekly", "five_hour"])
        #expect(event.source.handle == "thsottiaux")
        #expect(event.source.postID == "123")
        #expect(event.source.url.absoluteString == "https://x.com/thsottiaux/status/123")
        #expect(event.confidence == 0.98)
        #expect(event.rationale == "Explicit Codex quota reset announcement.")
        #expect(event.text == "I have reset usage limits for Codex.")
        #expect(snapshot.state == .yes)
        #expect(
            snapshot.evidenceLine(l10n: L10n(language: .english))
                == "An explicit Codex quota reset was announced.")
        #expect(
            snapshot.evidenceLine(l10n: L10n(language: .simplifiedChinese))
                == "发现明确的 Codex 配额重置公告。")
        #expect(snapshot.evidenceURL(now: now) == event.source.url)
    }

    @Test("completed reset is evaluated using the injected local calendar day")
    func completedResetUsesInjectedLocalDay() throws {
        let now = try resetStatusDate("2026-07-28T00:30:00Z")
        var singapore = Calendar(identifier: .gregorian)
        singapore.timeZone = try #require(TimeZone(identifier: "Asia/Singapore"))
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))

        let event = ResetStatusEventFixture(
            kind: "reset_completed",
            announcedAt: "2026-07-27T23:30:00Z")
        let singaporeSnapshot = try ResetStatusFeedFixture(event: event, now: now)
            .checked(at: "2026-07-28T00:30:00Z")
            .using(singapore)
            .decode()
        let losAngelesSnapshot = try ResetStatusFeedFixture(event: event, now: now)
            .checked(at: "2026-07-28T00:30:00Z")
            .using(losAngeles)
            .decode()

        #expect(singaporeSnapshot.state == .yes)
        #expect(losAngelesSnapshot.state == .yes)

        let earlierEvent = ResetStatusEventFixture(
            kind: "reset_completed",
            announcedAt: "2026-07-27T15:30:00Z")
        let previousSingaporeDay = try ResetStatusFeedFixture(event: earlierEvent, now: now)
            .checked(at: "2026-07-28T00:30:00Z")
            .using(singapore)
            .decode()
        let currentLosAngelesDay = try ResetStatusFeedFixture(event: earlierEvent, now: now)
            .checked(at: "2026-07-28T00:30:00Z")
            .using(losAngeles)
            .decode()
        #expect(previousSingaporeDay.state == .no)
        #expect(currentLosAngelesDay.state == .yes)
    }

    @Test("same-day scheduled reset counts as yes before and after effective time")
    func scheduledResetUsesLocalDay() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let pending = try ResetStatusFeedFixture(
            event: .init(
                kind: "reset_scheduled",
                announcedAt: "2026-07-28T09:00:00Z",
                effectiveAt: "2026-07-28T13:00:00Z"),
            now: now)
            .decode()
        let effective = try ResetStatusFeedFixture(
            event: .init(
                kind: "reset_scheduled",
                announcedAt: "2026-07-27T22:00:00Z",
                effectiveAt: "2026-07-28T11:00:00Z"),
            now: now)
            .decode()

        // Pending same-day schedule still means "yes, there is a reset today".
        #expect(pending.state == .yes)
        #expect(pending.hasAlreadyEffectiveResetToday(now: now) == false)
        #expect(pending.nextScheduledReset(now: now)?.event.source.postID != nil)
        #expect(effective.state == .yes)
        #expect(effective.hasAlreadyEffectiveResetToday(now: now) == true)
    }

    @Test("next same-day schedule outranks already-effective reset for primary evidence")
    func nextSameDayScheduleOutranksPastReset() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let calendar = resetStatusUTCCalendar
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: """
            {
              "kind": "reset_completed",
              "announcedAt": "2026-07-28T08:00:00.000Z",
              "effectiveAt": null,
              "scope": {"plans": ["all"], "windows": ["weekly"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "100",
                "url": "https://x.com/thsottiaux/status/100"
              },
              "confidence": 0.95,
              "rationale": "Explicit Codex quota reset announcement.",
              "text": "Limits reset this morning."
            },
            {
              "kind": "reset_scheduled",
              "announcedAt": "2026-07-28T09:00:00.000Z",
              "effectiveAt": "2026-07-28T20:00:00.000Z",
              "scope": {"plans": ["all"], "windows": ["weekly"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "200",
                "url": "https://x.com/thsottiaux/status/200"
              },
              "confidence": 0.88,
              "rationale": "Explicit Codex quota reset schedule.",
              "text": "Another reset later today."
            }
            """,
            now: now)
            .using(calendar)
            .decode()

        #expect(snapshot.resolvedState(now: now, calendar: calendar) == .yes)
        #expect(snapshot.hasAlreadyEffectiveResetToday(now: now, calendar: calendar) == true)
        #expect(snapshot.primaryEvidenceEvent(now: now, calendar: calendar)?.source.postID == "200")
        #expect(snapshot.nextScheduledReset(now: now)?.event.source.postID == "200")
    }

    @Test("future-day schedule alone is still no for today")
    func futureDayScheduleAloneIsNo() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            event: .init(
                kind: "reset_scheduled",
                announcedAt: "2026-07-28T09:00:00Z",
                effectiveAt: "2026-07-31T12:00:00Z"),
            now: now)
            .decode()
        #expect(snapshot.state == .no)
        #expect(snapshot.nextScheduledReset(now: now)?.event.source.postID != nil)
    }

    @Test(
        "non-reset event does not count as a reset",
        arguments: ["banked_reset", "limit_increase"])
    func nonResetEventDoesNotCount(kind: String) throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            event: .init(kind: kind, announcedAt: "2026-07-28T11:00:00Z"),
            now: now)
            .decode()
        #expect(snapshot.state == .no)
    }

    @Test("confirmed same-day reset wins over uncertain commentary")
    func confirmedResetWinsOverUncertain() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let uncertainOnly = try ResetStatusFeedFixture(
            event: .init(kind: "uncertain", announcedAt: "2026-07-28T11:00:00Z"),
            now: now)
            .decode()
        let confirmedWithUncertain = try ResetStatusFeedFixture(
            eventsJSON: """
            {
              "kind": "reset_completed",
              "announcedAt": "2026-07-28T10:00:00Z",
              "effectiveAt": null,
              "scope": {"plans": ["all"], "windows": ["weekly"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "456",
                "url": "https://x.com/thsottiaux/status/456"
              },
              "confidence": 0.99,
              "rationale": "Explicit Codex quota reset announcement.",
              "text": "I have reset usage limits."
            },
            {
              "kind": "uncertain",
              "announcedAt": "2026-07-28T11:00:00Z",
              "effectiveAt": null,
              "scope": {"plans": ["all"], "windows": ["unknown"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "789",
                "url": "https://x.com/thsottiaux/status/789"
              },
              "confidence": 0.5,
              "rationale": "Not a clear reset signal.",
              "text": "Something for everyone."
            }
            """,
            now: now)
            .decode()

        // Healthy feed with only uncertain commentary is "no", not "unavailable".
        #expect(uncertainOnly.state == .no)
        #expect(uncertainOnly.hasUncertainNoSignalToday(now: now) == true)
        #expect(confirmedWithUncertain.state == .yes)
    }

    @Test("healthy uncertain feed resolves to no with clear-signal copy")
    func healthyUncertainFeedResolvesToNo() throws {
        let now = try resetStatusDate("2026-08-02T08:10:25Z")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: """
            {
              "kind": "uncertain",
              "announcedAt": "2026-08-02T02:43:02Z",
              "effectiveAt": null,
              "scope": {"plans": ["unknown"], "windows": ["unknown"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "2083745358610342270",
                "url": "https://x.com/thsottiaux/status/2083745358610342270"
              },
              "confidence": 0.98,
              "rationale": "Not a clear reset signal.",
              "text": "Valid complaint. What would help?"
            }
            """,
            now: now)
            .checked(at: "2026-08-02T08:10:25Z")
            .decode()

        #expect(snapshot.state == .no)
        #expect(snapshot.hasUncertainNoSignalToday(now: now) == true)
        #expect(snapshot.primaryEvidenceEvent(now: now)?.kind == .uncertain)
        #expect(snapshot.scopeSummary(for: snapshot.events[0], l10n: L10n(language: .english)) == nil)
        #expect(
            snapshot.evidenceLine(l10n: L10n(language: .english), now: now)
                == "Not a clear reset signal.")
        #expect(
            snapshot.evidenceLine(l10n: L10n(language: .simplifiedChinese), now: now)
                == "不是明确的重置信号。")
    }

    @Test("degraded or stale monitor forces unknown")
    func degradedOrStaleMonitorForcesUnknown() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let event = ResetStatusEventFixture(
            kind: "reset_completed",
            announcedAt: "2026-07-28T11:00:00Z")
        let degraded = try ResetStatusFeedFixture(event: event, now: now)
            .monitor(status: "degraded", errorCode: "request_failed")
            .decode()
        let stale = try ResetStatusFeedFixture(event: event, now: now)
            .checked(at: "2026-07-27T05:59:59Z")
            .decode()
        let missingSuccess = try ResetStatusFeedFixture(event: event, now: now)
            .checked(at: nil)
            .decode()

        #expect(degraded.state == .unknown)
        #expect(degraded.monitor.errorCode == "request_failed")
        #expect(stale.state == .unknown)
        #expect(missingSuccess.state == .unknown)
    }

    @Test("exactly thirty hours old remains fresh")
    func thirtyHourBoundaryRemainsFresh() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            event: .init(
                kind: "reset_completed",
                announcedAt: "2026-07-28T11:00:00Z"),
            now: now)
            .checked(at: "2026-07-27T06:00:00Z")
            .decode()
        #expect(snapshot.state == .yes)
    }

    @Test("fresh feed without events means no reset today")
    func freshFeedWithoutEventsMeansNo() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(now: now).decode()
        #expect(snapshot.events.isEmpty)
        #expect(snapshot.state == .no)
    }

    @Test("resolved state changes at the next local midnight without refetching")
    func resolvedStateChangesAtLocalMidnight() throws {
        let beforeMidnight = try resetStatusDate("2026-07-28T23:59:00Z")
        let snapshot = try ResetStatusFeedFixture(
            event: .init(
                kind: "reset_completed",
                announcedAt: "2026-07-28T20:00:00Z"),
            now: beforeMidnight)
            .checked(at: "2026-07-28T23:50:00Z")
            .decode()

        #expect(snapshot.state == .yes)
        #expect(
            snapshot.resolvedState(
                now: try resetStatusDate("2026-07-29T00:01:00Z"),
                calendar: resetStatusUTCCalendar) == .no)
    }

    @Test("UTC date prefix is not treated as the local calendar day")
    func utcDatePrefixIsNotLocalDay() throws {
        // 2026-08-01T03:32:37Z is still 2026-07-31 evening in Los Angeles.
        let now = try resetStatusDate("2026-08-01T09:25:19Z")
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

        let snapshotLA = try ResetStatusFeedFixture(
            event: .init(kind: "reset_completed", announcedAt: "2026-08-01T03:32:37.000Z"),
            now: now)
            .checked(at: "2026-08-01T09:25:19Z")
            .using(losAngeles)
            .decode()
        let snapshotCN = try ResetStatusFeedFixture(
            event: .init(kind: "reset_completed", announcedAt: "2026-08-01T03:32:37.000Z"),
            now: now)
            .checked(at: "2026-08-01T09:25:19Z")
            .using(shanghai)
            .decode()

        #expect(snapshotLA.state == .no)
        #expect(snapshotCN.state == .yes)
        #expect(snapshotLA.hasAlreadyEffectiveResetToday(now: now, calendar: losAngeles) == false)
        #expect(snapshotCN.hasAlreadyEffectiveResetToday(now: now, calendar: shanghai) == true)
    }

    @Test("detected alert follows local day, not the UTC date string")
    func detectedAlertFollowsLocalDay() throws {
        let now = try resetStatusDate("2026-08-01T09:25:19Z")
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

        let previous = try ResetStatusFeedFixture(eventsJSON: "", now: now)
            .checked(at: "2026-08-01T09:25:19Z")
            .decode()
        let current = try ResetStatusFeedFixture(
            event: .init(kind: "reset_completed", announcedAt: "2026-08-01T03:32:37.000Z"),
            now: now)
            .checked(at: "2026-08-01T09:25:19Z")
            .decode()

        let laAlerts = RunwayAlertDecider.rateLimitResetTodayAlerts(
            previous: previous,
            current: current,
            now: now,
            calendar: losAngeles)
        let cnAlerts = RunwayAlertDecider.rateLimitResetTodayAlerts(
            previous: previous,
            current: current,
            now: now,
            calendar: shanghai)

        #expect(laAlerts.isEmpty)
        #expect(cnAlerts.count == 1)
        #expect(cnAlerts[0].kind == .rateLimitResetDetected)
    }

    @Test("decodes live status payload with fractional seconds and required text")
    func decodesLiveStatusPayloadShape() throws {
        let now = try resetStatusDate("2026-08-01T09:25:19Z")
        let data = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-08-01T09:25:19.679Z",
          "lastSuccessfulCheckAt": "2026-08-01T09:25:19.679Z",
          "monitor": {"status": "ok", "errorCode": null},
          "events": [
            {
              "kind": "reset_completed",
              "announcedAt": "2026-08-01T03:32:37.000Z",
              "effectiveAt": null,
              "scope": {"plans": ["all"], "windows": ["unknown"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "2083395449814229287",
                "url": "https://x.com/thsottiaux/status/2083395449814229287"
              },
              "confidence": 0.99,
              "rationale": "Explicit Codex quota reset announcement.",
              "text": "I have reset usage limits for Codex and ChatGPT Work."
            }
          ]
        }
        """.data(using: .utf8)!

        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let snapshot = try RateLimitResetTodaySnapshot.decode(
            from: data,
            now: now,
            calendar: shanghai)

        let expectedAnnouncedAt = try resetStatusDate("2026-08-01T03:32:37Z")
        #expect(snapshot.events.count == 1)
        #expect(snapshot.events[0].kind == .resetCompleted)
        #expect(snapshot.events[0].announcedAt == expectedAnnouncedAt)
        #expect(snapshot.events[0].text == "I have reset usage limits for Codex and ChatGPT Work.")
        #expect(snapshot.resolvedState(now: now, calendar: shanghai) == .yes)
        #expect(
            snapshot.evidenceLine(l10n: L10n(language: .english), now: now, calendar: shanghai)
                == "An explicit Codex quota reset was announced.")
    }

    @Test("rejects timestamps without a timezone offset")
    func rejectsTimestampsWithoutTimezone() throws {
        let now = try resetStatusDate("2026-08-01T12:00:00Z")
        let data = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-08-01T12:00:00",
          "lastSuccessfulCheckAt": "2026-08-01T12:00:00Z",
          "monitor": {"status": "ok", "errorCode": null},
          "events": []
        }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            try RateLimitResetTodaySnapshot.decode(from: data, now: now)
        }
    }

    @Test("same-day schedule evidence prefers local day even when global next is farther")
    func sameDayScheduleEvidencePrefersLocalDay() throws {
        // Two future same-day schedules: primary evidence should be the sooner one.
        let now = try resetStatusDate("2026-08-01T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: """
            {
              "kind": "reset_scheduled",
              "announcedAt": "2026-08-01T10:00:00.000Z",
              "effectiveAt": "2026-08-01T20:00:00.000Z",
              "scope": {"plans": ["all"], "windows": ["weekly"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "100",
                "url": "https://x.com/thsottiaux/status/100"
              },
              "confidence": 0.9,
              "rationale": "Explicit Codex quota reset schedule.",
              "text": "Reset tonight."
            },
            {
              "kind": "reset_scheduled",
              "announcedAt": "2026-08-01T11:00:00.000Z",
              "effectiveAt": "2026-08-01T15:00:00.000Z",
              "scope": {"plans": ["all"], "windows": ["weekly"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "200",
                "url": "https://x.com/thsottiaux/status/200"
              },
              "confidence": 0.9,
              "rationale": "Explicit Codex quota reset schedule.",
              "text": "Reset this afternoon."
            }
            """,
            now: now)
            .checked(at: "2026-08-01T12:00:00Z")
            .using(resetStatusUTCCalendar)
            .decode()

        #expect(snapshot.resolvedState(now: now, calendar: resetStatusUTCCalendar) == .yes)
        #expect(snapshot.nextScheduledReset(now: now)?.event.source.postID == "200")
        #expect(
            snapshot.nextScheduledReset(onLocalDayOf: now, calendar: resetStatusUTCCalendar)?
                .event.source.postID == "200")
        #expect(
            snapshot.primaryEvidenceEvent(now: now, calendar: resetStatusUTCCalendar)?
                .source.postID == "200")
    }

}
