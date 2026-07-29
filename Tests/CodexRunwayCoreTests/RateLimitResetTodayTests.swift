import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Rate limit reset today")
struct RateLimitResetTodayTests {
    @Test("uses the Codex reset CDN endpoints")
    func usesCodexResetCDNEndpoints() {
        #expect(RateLimitResetTodayClient.siteURL.absoluteString == "https://codexreset.gitcdn.top/")
        #expect(
            RateLimitResetTodayClient.statusURL.absoluteString
                == "https://codexreset.gitcdn.top/api/status.json")
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
              "rationale": "Explicit Codex quota reset schedule."
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
              "rationale": "Explicit Codex quota reset schedule."
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
              "rationale": "Explicit Codex quota reset announcement."
            }
            """,
            now: now)
            .decode()

        #expect(snapshot.state == .yes)
        #expect(snapshot.primaryEvidenceEvent(now: now)?.source.postID == "2082317452755751098")
        #expect(snapshot.nextScheduledReset(now: now)?.event.source.postID == "2082341416681001277")
        #expect(snapshot.evidenceURL?.absoluteString.contains("2082317452755751098") == true)
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
              "rationale": "Explicit Codex quota reset announcement."
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
        #expect(snapshot.state == .yes)
        #expect(
            snapshot.evidenceLine(l10n: L10n(language: .english))
                == "An explicit Codex quota reset was announced.")
        #expect(
            snapshot.evidenceLine(l10n: L10n(language: .simplifiedChinese))
                == "发现明确的 Codex 配额重置公告。")
        #expect(snapshot.evidenceURL == event.source.url)
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

    @Test("scheduled reset counts only after its effective time")
    func scheduledResetUsesEffectiveTime() throws {
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

        #expect(pending.state == .no)
        #expect(effective.state == .yes)
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
              "rationale": "Explicit Codex quota reset announcement."
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
              "rationale": "Relevant announcement could not be classified safely."
            }
            """,
            now: now)
            .decode()

        #expect(uncertainOnly.state == .unknown)
        #expect(confirmedWithUncertain.state == .yes)
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

}
