import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Rate limit reset today verdict")
struct RateLimitResetTodayVerdictTests {
    @Test("completed reset shows yes without a percent")
    func completedResetOmitsPercent() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            event: .init(
                kind: "reset_completed",
                announcedAt: "2026-07-28T04:09:02Z",
                effectiveAt: "2026-07-28T04:09:02Z"),
            now: now)
            .decode()
        let presentation = snapshot.verdictPresentation(now: now, calendar: resetStatusUTCCalendar)

        #expect(presentation.showsYes)
        #expect(presentation.isCompleted)
        #expect(!presentation.isScheduled)
        #expect(presentation.percent == nil)
        #expect(presentation.band == nil)
        #expect(presentation.resetType == .global)
        #expect(presentation.titleText(l10n: L10n(language: .english)) == "Yes")
        #expect(presentation.titleText(l10n: L10n(language: .simplifiedChinese)) == "是")
    }

    @Test("scheduled reset shows percent plus yes and a confidence band")
    func scheduledResetShowsPercentAndBand() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        var snapshot = try pendingSchedule(confidence: 0.98, now: now)
        var presentation = snapshot.verdictPresentation(now: now, calendar: resetStatusUTCCalendar)
        #expect(presentation.showsYes)
        #expect(presentation.isScheduled)
        #expect(!presentation.isCompleted)
        #expect(presentation.percent == 98)
        #expect(presentation.band == .ok)
        #expect(presentation.percentText(l10n: L10n(language: .english)) == "≥98%")
        #expect(presentation.titleText(l10n: L10n(language: .simplifiedChinese)) == "≥98%是")

        snapshot.events[0].confidence = 0.6
        presentation = snapshot.verdictPresentation(now: now, calendar: resetStatusUTCCalendar)
        #expect(presentation.percent == 60)
        #expect(presentation.band == .warn)
        #expect(presentation.percentText(l10n: L10n(language: .english)) == "≥60%")

        snapshot.events[0].confidence = 1
        presentation = snapshot.verdictPresentation(now: now, calendar: resetStatusUTCCalendar)
        #expect(presentation.percent == 100)
        #expect(presentation.band == .ok)
        #expect(presentation.percentText(l10n: L10n(language: .english)) == "100%")
        #expect(presentation.titleText(l10n: L10n(language: .english)) == "100%Yes")
    }

    @Test("completed copy names type, percent, and local time")
    func confirmedDetailMatchesHostedCopy() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            event: .init(
                kind: "reset_completed",
                announcedAt: "2026-07-28T04:09:02Z",
                effectiveAt: "2026-07-28T04:09:02Z"),
            now: now)
            .decode()
        let l10n = L10n(language: .simplifiedChinese)
        let detail = try #require(
            snapshot.verdictDetail(l10n: l10n, now: now, calendar: resetStatusUTCCalendar))
        let ago = try #require(
            DurationFormatter.relativePastSingleUnit(
                since: try resetStatusDate("2026-07-28T04:09:02Z"),
                now: now,
                language: .simplifiedChinese))
        let when = String(format: l10n.text(.rateLimitResetTodayConfirmedWhen), "2026/7/28 04:09", ago)

        #expect(detail.resetType == .global)
        #expect(detail.typeLabel == "全局重置")
        #expect(detail.percentText == "98%")
        #expect(detail.timeText == when)
        #expect(detail.plainText == "监测到今天已有完成的全局重置，置信度约为98%，重置的本地时间为\(when)")
        #expect(detail.tokens.contains(.resetType))
        #expect(detail.tokens.contains(.percent))
        #expect(detail.tokens.contains(.time))
    }

    @Test("scheduled copy uses chance text and keeps percent as a prefix")
    func scheduledChanceDetailMatchesHostedCopy() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try pendingSchedule(confidence: 0.92, now: now)
        let l10n = L10n(language: .simplifiedChinese)
        let detail = try #require(
            snapshot.verdictDetail(l10n: l10n, now: now, calendar: resetStatusUTCCalendar))

        #expect(detail.resetType == .global)
        #expect(detail.percentText == "≥92%")
        #expect(detail.timeText == "2026/7/28 13:00")
        #expect(
            detail.plainText
                == "约≥92%的可能性会进行全局重置，目前计划已排期，重置时间范围大约在本地时间：2026/7/28 13:00")
        #expect(detail.tokens.contains(.resetType))
        #expect(detail.tokens.contains(.time))
        #expect(!detail.tokens.contains(.percent))
    }

    @Test("completed reset wins over a later scheduled event")
    func completedResetOutranksSchedule() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: """
            {
              "kind": "reset_completed",
              "announcedAt": "2026-07-28T04:09:02Z",
              "effectiveAt": "2026-07-28T04:09:02Z",
              "scope": {"plans": ["all"], "windows": ["weekly"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "1",
                "url": "https://x.com/thsottiaux/status/1"
              },
              "confidence": 0.98,
              "rationale": "Explicit Codex quota reset announcement.",
              "text": "Reset completed."
            },
            {
              "kind": "reset_scheduled",
              "announcedAt": "2026-07-28T11:00:00Z",
              "effectiveAt": "2026-07-29T13:00:00Z",
              "schedulePrecision": "datetime",
              "scope": {"plans": ["all"], "windows": ["weekly"]},
              "source": {
                "handle": "thsottiaux",
                "postId": "2",
                "url": "https://x.com/thsottiaux/status/2"
              },
              "confidence": 0.6,
              "rationale": "Explicit Codex quota reset schedule.",
              "text": "Another reset tomorrow."
            }
            """,
            now: now)
            .decode()
        let presentation = snapshot.verdictPresentation(now: now, calendar: resetStatusUTCCalendar)
        #expect(presentation.isCompleted)
        #expect(!presentation.isScheduled)
        #expect(presentation.percent == nil)
        #expect(snapshot.scheduleConfidenceBand(for: snapshot.events[1]) == .warn)
    }

    @Test("schedule grace is half open for exactly three hours")
    func graceUsesHalfOpenThreeHourWindow() throws {
        let pendingUntil = try resetStatusDate("2026-07-28T13:00:00Z")
        let snapshot = makeSnapshot(
            now: pendingUntil,
            events: [scheduled(at: pendingUntil, confidence: 0.92)])

        var presentation = snapshot.verdictPresentation(
            now: pendingUntil,
            calendar: resetStatusUTCCalendar)
        #expect(presentation.reason == .grace)
        #expect(presentation.showsYes)
        #expect(presentation.percent == 92)

        presentation = snapshot.verdictPresentation(
            now: pendingUntil.addingTimeInterval(3 * 3_600 - 1),
            calendar: resetStatusUTCCalendar)
        #expect(presentation.reason == .grace)

        presentation = snapshot.verdictPresentation(
            now: pendingUntil.addingTimeInterval(3 * 3_600),
            calendar: resetStatusUTCCalendar)
        #expect(presentation.reason == .expiredUnconfirmed)
        #expect(!presentation.showsYes)
        #expect(presentation.confidence == nil)
        #expect(presentation.scheduleWindow == nil)
        #expect(presentation.evidenceEvent == nil)
    }

    @Test("freshness uses the newest producer timestamp and expires after thirty hours")
    func freshnessUsesNewestTimestamp() throws {
        let generatedAt = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = makeSnapshot(
            now: generatedAt,
            generatedAt: generatedAt,
            lastSuccessfulCheckAt: generatedAt.addingTimeInterval(-40 * 3_600))

        #expect(snapshot.freshnessAt == generatedAt)
        #expect(snapshot.verdictPresentation(
            now: generatedAt.addingTimeInterval(30 * 3_600),
            calendar: resetStatusUTCCalendar).reason == .none)
        #expect(snapshot.verdictPresentation(
            now: generatedAt.addingTimeInterval(30 * 3_600 + 1),
            calendar: resetStatusUTCCalendar).reason == .unavailable)
    }

    @Test("unavailable detail distinguishes monitor health from stale data")
    func unavailableDetailExplainsSafeCause() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let l10n = L10n(language: .english)
        let stale = makeSnapshot(
            now: now,
            generatedAt: now.addingTimeInterval(-31 * 3_600),
            lastSuccessfulCheckAt: now.addingTimeInterval(-31 * 3_600))
        let degraded = RateLimitResetTodaySnapshot(
            response: RateLimitResetTodayResponse(
                schemaVersion: 1,
                generatedAt: now,
                lastSuccessfulCheckAt: now,
                monitor: RateLimitResetTodayMonitor(status: .degraded, errorCode: "secret_detail"),
                events: []),
            now: now,
            calendar: resetStatusUTCCalendar)

        #expect(stale.verdictDetail(
            l10n: l10n,
            now: now,
            calendar: resetStatusUTCCalendar)?.plainText
            == l10n.text(.rateLimitResetTodayUnavailableStaleHint))
        let monitorText = degraded.verdictDetail(
            l10n: l10n,
            now: now,
            calendar: resetStatusUTCCalendar)?.plainText
        #expect(monitorText == l10n.text(.rateLimitResetTodayUnavailableMonitorHint))
        #expect(monitorText?.contains("secret_detail") == false)
    }

    @Test("same-time global and banked schedules merge with minimum confidence")
    func matchingSchedulesMergeTypesAndConfidence() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let at = try resetStatusDate("2026-07-29T12:00:00Z")
        let global = scheduled(at: at, resetType: .global, confidence: 0.92, postID: "1")
        var banked = scheduled(at: at, resetType: .banked, confidence: 0.76, postID: "2")
        banked.scheduleBasis = .contextualInference
        let snapshot = makeSnapshot(now: now, events: [global, banked])

        let presentation = snapshot.verdictPresentation(now: now, calendar: resetStatusUTCCalendar)
        #expect(presentation.reason == .upcoming)
        #expect(presentation.resetType == .globalAndBanked)
        #expect(presentation.confidence == 0.76)
        #expect(presentation.percent == 76)
        #expect(presentation.band == .warn)
        #expect(presentation.scheduleBasis == .explicit)
    }

    @Test("contextual schedule remains a prediction rather than today's completed fact")
    func contextualScheduleIsPrediction() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let at = try resetStatusDate("2026-07-28T13:00:00Z")
        var event = scheduled(at: at, confidence: 0.81)
        event.scheduleBasis = .contextualInference
        let snapshot = makeSnapshot(now: now, events: [event])

        let presentation = snapshot.verdictPresentation(now: now, calendar: resetStatusUTCCalendar)
        #expect(presentation.reason == .upcoming)
        #expect(presentation.showsYes)
        #expect(!presentation.isCompleted)
        #expect(snapshot.resolvedState(now: now, calendar: resetStatusUTCCalendar) == .yes)
    }

    @Test("suppressed schedule cannot enter grace and expired evidence is cleared")
    func suppressedScheduleCannotEnterGrace() throws {
        let now = try resetStatusDate("2026-07-28T13:30:00Z")
        let event = scheduled(
            at: try resetStatusDate("2026-07-28T13:00:00Z"),
            confidence: 0.92,
            postID: "9")
        let timeline = RateLimitResetTimeline(suppressedPostIds: ["9"])
        let snapshot = makeSnapshot(now: now, events: [event], timeline: timeline)

        let presentation = snapshot.verdictPresentation(now: now, calendar: resetStatusUTCCalendar)
        #expect(presentation.reason == .expiredUnconfirmed)
        #expect(presentation.resetType == nil)
        #expect(presentation.confidence == nil)
        #expect(presentation.evidenceEvent == nil)
    }

    @Test("fulfilled schedule cannot re-enter grace")
    func fulfilledScheduleCannotEnterGrace() throws {
        let now = try resetStatusDate("2026-07-28T13:30:00Z")
        let at = try resetStatusDate("2026-07-28T13:00:00Z")
        let event = scheduled(at: at, confidence: 0.92, postID: "9")
        let fulfilled = RateLimitResetFulfilledSchedule(
            schedule: event,
            window: RateLimitResetPublishedWindow(
                startAt: at,
                endAt: at,
                precision: .datetime),
            completionPostID: "10",
            completedAt: at,
            visibleUntil: now.addingTimeInterval(3_600))
        let snapshot = makeSnapshot(
            now: now,
            events: [event],
            timeline: RateLimitResetTimeline(fulfilledSchedules: [fulfilled]))

        #expect(snapshot.verdictPresentation(
            now: now,
            calendar: resetStatusUTCCalendar).reason == .expiredUnconfirmed)
    }

    @Test("manual completion produces a completed verdict without confidence")
    func manualCompletionIsCompleted() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let manual = RateLimitResetManualCompletion(
            id: "manual:1",
            completedAt: now.addingTimeInterval(-300),
            visibleUntil: now.addingTimeInterval(3_600),
            representativePostID: "1",
            schedulePostIDs: [],
            schedules: [])
        let snapshot = makeSnapshot(
            now: now,
            timeline: RateLimitResetTimeline(manualCompletions: [manual]))

        let presentation = snapshot.verdictPresentation(now: now, calendar: resetStatusUTCCalendar)
        #expect(presentation.reason == .completed)
        #expect(presentation.resetType == .global)
        #expect(presentation.completedAt == manual.completedAt)
        #expect(presentation.percent == nil)
        #expect(presentation.confidence == nil)
    }

    @Test("Los Angeles date schedule keeps its DST midnight and grace boundary")
    func losAngelesDSTScheduleBoundary() throws {
        let start = try resetStatusDate("2026-03-08T08:00:00Z")
        var event = scheduled(at: start, confidence: 0.9)
        event.schedulePrecision = .date
        let pendingUntil = try resetStatusDate("2026-03-09T07:00:00Z")
        let snapshot = makeSnapshot(now: pendingUntil, events: [event], generatedAt: pendingUntil)

        #expect(snapshot.scheduledResetWindow(for: event)?.pendingUntil == pendingUntil)
        #expect(snapshot.verdictPresentation(
            now: pendingUntil,
            calendar: resetStatusUTCCalendar).reason == .grace)
    }

    @Test("completed verdict ends at the local Gregorian midnight")
    func completionEndsAtLocalMidnight() throws {
        let now = try resetStatusDate("2026-07-29T00:00:00Z")
        let event = RateLimitResetTodayEvent(
            kind: .resetCompleted,
            announcedAt: now.addingTimeInterval(-1),
            effectiveAt: now.addingTimeInterval(-1),
            scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
            source: RateLimitResetTodaySource(postID: "1"),
            confidence: 0.98,
            rationale: "Explicit Codex quota reset announcement.",
            text: "Reset completed.")
        let snapshot = makeSnapshot(now: now, events: [event])

        #expect(snapshot.verdictPresentation(
            now: now,
            calendar: resetStatusUTCCalendar).reason == .none)
    }

    @Test("transition dates include schedule, manual, stale, and local-day boundaries")
    func transitionDatesCoverEveryVerdictBoundary() throws {
        let now = try resetStatusDate("2026-07-28T23:00:00Z")
        let scheduleAt = try resetStatusDate("2026-07-29T08:00:00Z")
        let event = scheduled(at: scheduleAt, confidence: 0.9)
        let manual = RateLimitResetManualCompletion(
            id: "manual:1",
            completedAt: now.addingTimeInterval(600),
            visibleUntil: now.addingTimeInterval(1_200),
            representativePostID: "1",
            schedulePostIDs: [],
            schedules: [])
        let snapshot = makeSnapshot(
            now: now,
            timeline: RateLimitResetTimeline(
                nextSchedule: event,
                manualCompletions: [manual]))
        let dates = snapshot.nextVerdictTransitionDates(
            now: now,
            calendar: resetStatusUTCCalendar)

        #expect(dates.contains(scheduleAt))
        #expect(dates.contains(scheduleAt.addingTimeInterval(3 * 3_600)))
        #expect(dates.contains(manual.completedAt))
        #expect(dates.contains(manual.visibleUntil.addingTimeInterval(1)))
        #expect(dates.contains(now.addingTimeInterval(30 * 3_600 + 1)))
        #expect(dates.contains(try resetStatusDate("2026-07-29T00:00:00Z")))
        #expect(dates.contains(try resetStatusDate("2026-07-30T00:00:00Z")))
        #expect(dates.allSatisfy { $0.timeIntervalSince1970.rounded() == $0.timeIntervalSince1970 })
    }

    @Test("completed status keeps feed priority while evidence and detail use latest records")
    func completedStatusAndEvidenceFollowReferenceOrdering() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        var first = completed(at: now.addingTimeInterval(-3_600), confidence: 0.6, postID: "1")
        first.announcedAt = now.addingTimeInterval(-3_500)
        let second = completed(at: now.addingTimeInterval(-1_800), confidence: 0.98, postID: "2")
        let manual = RateLimitResetManualCompletion(
            id: "manual:1",
            completedAt: now.addingTimeInterval(-600),
            visibleUntil: now.addingTimeInterval(3_600),
            representativePostID: "3",
            schedulePostIDs: [],
            schedules: [])
        let snapshot = makeSnapshot(
            now: now,
            events: [first, second],
            timeline: RateLimitResetTimeline(manualCompletions: [manual]))

        let presentation = snapshot.verdictPresentation(now: now, calendar: resetStatusUTCCalendar)
        #expect(presentation.confidence == 0.6)
        #expect(presentation.evidenceEvent?.source.postID == "2")
        #expect(presentation.completedAt == manual.completedAt)
    }

    @Test("developer mocks cover every verdict lifecycle")
    func developerMocksCoverLifecycle() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let expected: [(RateLimitResetTodaySnapshot.DevMockKind, RateLimitResetTodayVerdictReason)] = [
            (.completed, .completed),
            (.explicitScheduled, .upcoming),
            (.inferredScheduled, .upcoming),
            (.grace, .grace),
            (.expired, .expiredUnconfirmed),
            (.unavailable, .unavailable),
        ]
        for (kind, reason) in expected {
            let snapshot = RateLimitResetTodaySnapshot.devMock(kind: kind, now: now)
            #expect(snapshot.verdictPresentation(
                now: now,
                calendar: resetStatusUTCCalendar).reason == reason)
        }
    }

    private func makeSnapshot(
        now: Date,
        events: [RateLimitResetTodayEvent] = [],
        timeline: RateLimitResetTimeline? = nil,
        generatedAt: Date? = nil,
        lastSuccessfulCheckAt: Date? = nil) -> RateLimitResetTodaySnapshot
    {
        RateLimitResetTodaySnapshot(
            response: RateLimitResetTodayResponse(
                schemaVersion: 1,
                generatedAt: generatedAt ?? now,
                lastSuccessfulCheckAt: lastSuccessfulCheckAt ?? now,
                monitor: RateLimitResetTodayMonitor(status: .ok),
                events: events,
                resetTimeline: timeline),
            now: now,
            calendar: resetStatusUTCCalendar)
    }

    private func scheduled(
        at: Date,
        resetType: RateLimitResetType = .global,
        confidence: Double,
        postID: String = "1") -> RateLimitResetTodayEvent
    {
        RateLimitResetTodayEvent(
            kind: .resetScheduled,
            resetType: resetType,
            announcedAt: at.addingTimeInterval(-3_600),
            effectiveAt: at,
            schedulePrecision: .datetime,
            scheduleBasis: .explicit,
            scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
            source: RateLimitResetTodaySource(postID: postID),
            confidence: confidence,
            rationale: "Explicit Codex quota reset schedule.",
            text: "Scheduled reset.")
    }

    private func completed(
        at: Date,
        confidence: Double,
        postID: String) -> RateLimitResetTodayEvent
    {
        RateLimitResetTodayEvent(
            kind: .resetCompleted,
            announcedAt: at,
            effectiveAt: at,
            scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
            source: RateLimitResetTodaySource(postID: postID),
            confidence: confidence,
            rationale: "Explicit Codex quota reset announcement.",
            text: "Reset completed.")
    }

    private func pendingSchedule(confidence: Double, now: Date) throws -> RateLimitResetTodaySnapshot {
        var snapshot = try ResetStatusFeedFixture(
            event: .init(
                kind: "reset_scheduled",
                announcedAt: "2026-07-28T09:00:00Z",
                effectiveAt: "2026-07-28T13:00:00Z",
                schedulePrecision: "datetime"),
            now: now)
            .decode()
        snapshot.events[0].confidence = confidence
        return snapshot
    }
}
