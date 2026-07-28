import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Rate limit reset today validation")
struct RateLimitResetTodayValidationTests {
    @Test("rejects internally inconsistent monitor and event data")
    func rejectsInconsistentFeedData() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let completed = ResetStatusEventFixture(
            kind: "reset_completed",
            announcedAt: "2026-07-28T11:00:00Z")

        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(event: completed, now: now)
                .monitor(status: "ok", errorCode: "request_failed")
                .decode()
        }
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(
                event: .init(
                    kind: "reset_scheduled",
                    announcedAt: "2026-07-28T11:00:00Z"),
                now: now)
                .decode()
        }
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(
                event: .init(
                    kind: "limit_increase",
                    announcedAt: "2026-07-28T11:00:00Z",
                    effectiveAt: "2026-07-28T11:30:00Z"),
                now: now)
                .decode()
        }
        #expect(throws: DecodingError.self) {
            try ResetStatusFeedFixture(
                eventsJSON: """
                {
                  "kind": "reset_completed",
                  "announcedAt": "2026-07-28T11:00:00Z",
                  "effectiveAt": null,
                  "scope": {"plans": ["all"], "windows": ["weekly"]},
                  "source": {
                    "handle": "thsottiaux",
                    "postId": "123",
                    "url": "https://x.com/thsottiaux/status/123"
                  },
                  "confidence": 0.98,
                  "rationale": "Copied post text is not a derived explanation."
                }
                """,
                now: now)
                .decode()
        }
    }

    @Test("rejects unsupported schema version")
    func rejectsUnsupportedSchemaVersion() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let data = """
        {
          "schemaVersion": 2,
          "generatedAt": "2026-07-28T12:00:00Z",
          "lastSuccessfulCheckAt": "2026-07-28T12:00:00Z",
          "monitor": {"status": "ok", "errorCode": null},
          "events": []
        }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            try RateLimitResetTodaySnapshot.decode(from: data, now: now)
        }
    }

    @Test("development fixtures no longer expose a reset countdown")
    func developmentFixturesUseEventSemantics() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yes = RateLimitResetTodaySnapshot.devMock(kind: .yes, now: now)
        let no = RateLimitResetTodaySnapshot.devMock(kind: .no, now: now)
        let unknown = RateLimitResetTodaySnapshot.devMock(kind: .unknown, now: now)

        #expect(yes.state == .yes)
        #expect(yes.events.first?.kind == .resetCompleted)
        #expect(no.state == .no)
        #expect(unknown.state == .unknown)
        #expect(RateLimitResetTodaySnapshot.DevMockKind.parse("yes-countdown") == nil)
    }
}
