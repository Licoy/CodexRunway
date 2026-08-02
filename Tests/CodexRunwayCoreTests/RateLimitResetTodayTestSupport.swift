import Foundation
@testable import CodexRunwayCore

struct ResetStatusEventFixture {
    var kind: String
    var announcedAt: String
    var effectiveAt: String? = nil

    var json: String {
        let effectiveValue = effectiveAt.map { "\"\($0)\"" } ?? "null"
        return """
        {
          "kind": "\(kind)",
          "announcedAt": "\(announcedAt)",
          "effectiveAt": \(effectiveValue),
          "scope": {"plans": ["all"], "windows": ["weekly"]},
          "source": {
            "handle": "thsottiaux",
            "postId": "123",
            "url": "https://x.com/thsottiaux/status/123"
          },
          "confidence": 0.98,
          "rationale": "\(rationale)",
          "text": "fixture post text for \(kind)"
        }
        """
    }

    private var rationale: String {
        switch kind {
        case "reset_completed":
            "Explicit Codex quota reset announcement."
        case "reset_scheduled":
            "Explicit Codex quota reset schedule."
        case "banked_reset":
            "Banked reset announcement; not a completed reset."
        case "limit_increase":
            "Quota limit increase announcement; not a reset."
        default:
            "Not a clear reset signal."
        }
    }
}

struct ResetStatusFeedFixture {
    var eventsJSON: String
    var lastSuccessfulCheckAt: String? = "2026-07-28T12:00:00Z"
    var monitorStatus = "ok"
    var errorCode: String?
    var now: Date
    var calendar: Calendar = resetStatusUTCCalendar

    init(event: ResetStatusEventFixture, now: Date) {
        self.eventsJSON = event.json
        self.now = now
    }

    init(eventsJSON: String = "", now: Date) {
        self.eventsJSON = eventsJSON
        self.now = now
    }

    func checked(at value: String?) -> ResetStatusFeedFixture {
        var copy = self
        copy.lastSuccessfulCheckAt = value
        return copy
    }

    func using(_ calendar: Calendar) -> ResetStatusFeedFixture {
        var copy = self
        copy.calendar = calendar
        return copy
    }

    func monitor(status: String, errorCode: String?) -> ResetStatusFeedFixture {
        var copy = self
        copy.monitorStatus = status
        copy.errorCode = errorCode
        return copy
    }

    func decode() throws -> RateLimitResetTodaySnapshot {
        let lastSuccessValue = lastSuccessfulCheckAt.map { "\"\($0)\"" } ?? "null"
        let errorValue = errorCode.map { "\"\($0)\"" } ?? "null"
        let data = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-28T12:00:00Z",
          "lastSuccessfulCheckAt": \(lastSuccessValue),
          "monitor": {"status": "\(monitorStatus)", "errorCode": \(errorValue)},
          "events": [\(eventsJSON)]
        }
        """.data(using: .utf8)!
        return try RateLimitResetTodaySnapshot.decode(
            from: data,
            now: now,
            calendar: calendar)
    }
}

func resetStatusDate(_ value: String) throws -> Date {
    try Date(value, strategy: .iso8601)
}

let resetStatusUTCCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()
