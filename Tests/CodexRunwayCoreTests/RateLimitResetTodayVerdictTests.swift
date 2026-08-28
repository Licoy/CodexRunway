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
