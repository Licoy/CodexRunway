import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Rate limit reset types")
struct RateLimitResetTypeTests {
    @Test("decodes all reset types and defaults legacy events to global")
    func decodesResetTypes() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let cases: [(String?, RateLimitResetType)] = [
            (nil, .global),
            ("global", .global),
            ("banked", .banked),
            ("global_and_banked", .globalAndBanked),
        ]

        for (rawValue, expected) in cases {
            let snapshot = try ResetStatusFeedFixture(
                event: .init(
                    kind: "reset_completed",
                    resetType: rawValue,
                    announcedAt: "2026-07-28T11:00:00Z"),
                now: now)
                .decode()
            #expect(snapshot.events.first?.resetType == expected)
        }
    }

    @Test("rejects explicit null and unknown reset types")
    func rejectsInvalidResetTypes() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let valid = ResetStatusEventFixture(
            kind: "reset_completed",
            resetType: "global",
            announcedAt: "2026-07-28T11:00:00Z")
            .json
        let explicitNull = valid.replacingOccurrences(
            of: "\"resetType\": \"global\"",
            with: "\"resetType\": null")

        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(eventsJSON: explicitNull, now: now).decode()
        }
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(
                event: .init(
                    kind: "reset_completed",
                    resetType: "future_type",
                    announcedAt: "2026-07-28T11:00:00Z"),
                now: now)
                .decode()
        }
    }

    @Test("validates reset type against event kind and rationale")
    func validatesKindAndRationale() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let bankedOrigin = try ResetStatusFeedFixture(
            event: .init(
                kind: "banked_reset",
                resetType: "banked",
                announcedAt: "2026-07-28T11:00:00Z"),
            now: now)
            .decode()
        #expect(bankedOrigin.events.first?.resetType == .banked)

        for event in [
            ResetStatusEventFixture(
                kind: "banked_reset",
                resetType: "global_and_banked",
                announcedAt: "2026-07-28T11:00:00Z"),
            ResetStatusEventFixture(
                kind: "limit_increase",
                resetType: "banked",
                announcedAt: "2026-07-28T11:00:00Z"),
            ResetStatusEventFixture(
                kind: "uncertain",
                resetType: "banked",
                announcedAt: "2026-07-28T11:00:00Z"),
        ] {
            #expect(throws: DecodingError.self) {
                try ResetStatusFeedFixture(event: event, now: now).decode()
            }
        }

        let bankedCompletion = ResetStatusEventFixture(
            kind: "reset_completed",
            resetType: "banked",
            announcedAt: "2026-07-28T11:00:00Z")
            .json
        let mismatchedRationale = bankedCompletion.replacingOccurrences(
            of: "Explicit Codex reset-bank credit announcement.",
            with: "Explicit Codex quota reset announcement.")
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(eventsJSON: mismatchedRationale, now: now).decode()
        }
    }

    @Test("accepts every canonical typed completion and schedule rationale")
    func acceptsCanonicalTypedRationales() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let resetTypes = ["global", "banked", "global_and_banked"]

        for (index, resetType) in resetTypes.enumerated() {
            let completed = ResetStatusEventFixture(
                kind: "reset_completed",
                resetType: resetType,
                announcedAt: "2026-07-28T11:00:00Z",
                postID: "10\(index)")
            let explicitSchedule = ResetStatusEventFixture(
                kind: "reset_scheduled",
                resetType: resetType,
                announcedAt: "2026-07-28T10:00:00Z",
                effectiveAt: "2026-07-28T14:00:00Z",
                schedulePrecision: "datetime",
                scheduleBasis: "explicit",
                postID: "20\(index)")
            let contextualSchedule = ResetStatusEventFixture(
                kind: "reset_scheduled",
                resetType: resetType,
                announcedAt: "2026-07-28T10:00:00Z",
                effectiveAt: "2026-07-28T15:00:00Z",
                schedulePrecision: "datetime",
                scheduleBasis: "contextual_inference",
                postID: "30\(index)")

            let snapshot = try ResetStatusFeedFixture(
                eventsJSON: "\(completed.json),\n\(explicitSchedule.json),\n\(contextualSchedule.json)",
                now: now)
                .decode()
            #expect(snapshot.events.count == 3)
        }
    }

    @Test("timeline next schedule must contain a global reset")
    func timelineNextScheduleRequiresGlobal() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let banked = ResetStatusEventFixture(
            kind: "reset_scheduled",
            resetType: "banked",
            announcedAt: "2026-07-28T10:00:00Z",
            effectiveAt: "2026-07-28T14:00:00Z",
            postID: "200")

        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(event: banked, now: now)
                .withTimeline(
                    resetStatusEmptyTimelineJSON(
                        nextScheduleJSON: banked.json,
                        recentNonCompletedPostId: "200"))
                .decode()
        }
    }

    @Test("display type merges completed types while latest reset keeps the newest type")
    func displayAndLatestResetTypes() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let global = ResetStatusEventFixture(
            kind: "reset_completed",
            resetType: "global",
            announcedAt: "2026-07-28T10:00:00Z",
            postID: "100")
        let banked = ResetStatusEventFixture(
            kind: "reset_completed",
            resetType: "banked",
            announcedAt: "2026-07-28T11:00:00Z",
            postID: "200")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: "\(global.json),\n\(banked.json)",
            now: now)
            .decode()

        #expect(snapshot.displayResetType(now: now, calendar: resetStatusUTCCalendar) == .globalAndBanked)
        let expectedLatestAt = try resetStatusDate("2026-07-28T11:00:00Z")
        #expect(snapshot.latestReset(now: now)?.at == expectedLatestAt)
        #expect(snapshot.latestReset(now: now)?.resetType == .banked)
        #expect(snapshot.latestResetAt(now: now) == snapshot.latestReset(now: now)?.at)
        #expect(
            snapshot.evidenceLine(
                l10n: L10n(language: .english),
                now: now,
                calendar: resetStatusUTCCalendar)
                == "A reset-bank credit was confirmed available for on-demand use.")
    }

    @Test("latest reset merges types that complete at the same instant")
    func latestResetMergesSameInstant() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let global = ResetStatusEventFixture(
            kind: "reset_completed",
            resetType: "global",
            announcedAt: "2026-07-28T11:00:00Z",
            postID: "100")
        let banked = ResetStatusEventFixture(
            kind: "reset_completed",
            resetType: "banked",
            announcedAt: "2026-07-28T11:00:00Z",
            postID: "200")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: "\(global.json),\n\(banked.json)",
            now: now)
            .decode()

        #expect(snapshot.latestReset(now: now)?.resetType == .globalAndBanked)
    }

    @Test("timeline considers unsuppressed banked-only schedules")
    func timelineIncludesBankedOnlySchedules() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let global = ResetStatusEventFixture(
            kind: "reset_scheduled",
            resetType: "global",
            announcedAt: "2026-07-28T10:00:00Z",
            effectiveAt: "2026-07-28T16:00:00Z",
            postID: "100")
        let banked = ResetStatusEventFixture(
            kind: "reset_scheduled",
            resetType: "banked",
            announcedAt: "2026-07-28T11:00:00Z",
            effectiveAt: "2026-07-28T14:00:00Z",
            postID: "200")
        let events = "\(global.json),\n\(banked.json)"
        let timeline = resetStatusEmptyTimelineJSON(
            nextScheduleJSON: global.json,
            recentNonCompletedPostId: "100")
        let snapshot = try ResetStatusFeedFixture(eventsJSON: events, now: now)
            .withTimeline(timeline)
            .decode()

        #expect(snapshot.state == .yes)
        #expect(snapshot.nextScheduledReset(now: now)?.event.source.postID == "200")
        #expect(snapshot.displayResetType(now: now, calendar: resetStatusUTCCalendar) == .banked)

        let suppressed = try ResetStatusFeedFixture(eventsJSON: events, now: now)
            .withTimeline(
                resetStatusEmptyTimelineJSON(
                    nextScheduleJSON: global.json,
                    recentNonCompletedPostId: "100",
                    suppressedJSON: "\"200\""))
            .decode()
        #expect(suppressed.nextScheduledReset(now: now)?.event.source.postID == "100")
        #expect(suppressed.displayResetType(now: now, calendar: resetStatusUTCCalendar) == .global)
    }

    @Test("manual completion merges the types of its schedules")
    func manualCompletionMergesScheduleTypes() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let global = ResetStatusEventFixture(
            kind: "reset_scheduled",
            resetType: "global",
            announcedAt: "2026-07-28T08:00:00Z",
            effectiveAt: "2026-07-28T09:00:00Z",
            postID: "100")
        let banked = ResetStatusEventFixture(
            kind: "reset_scheduled",
            resetType: "banked",
            announcedAt: "2026-07-28T08:30:00Z",
            effectiveAt: "2026-07-28T09:00:00Z",
            postID: "200")
        let manual = """
        {
          "id": "manual:mixed",
          "completedAt": "2026-07-28T10:00:00Z",
          "visibleUntil": "2026-08-07T10:00:00Z",
          "representativePostId": "100",
          "schedulePostIds": ["100", "200"],
          "schedules": [\(global.json), \(banked.json)],
          "fulfillmentOrigin": "manual"
        }
        """
        let snapshot = try ResetStatusFeedFixture(eventsJSON: "", now: now)
            .withTimeline(resetStatusEmptyTimelineJSON(manualJSON: manual))
            .decode()

        #expect(snapshot.displayResetType(now: now, calendar: resetStatusUTCCalendar) == .globalAndBanked)
        #expect(snapshot.latestReset(now: now)?.resetType == .globalAndBanked)
    }
}
