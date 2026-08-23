import Foundation
@testable import CodexRunwayCore

struct ResetStatusEventFixture {
    var kind: String
    var resetType: String? = nil
    var announcedAt: String
    var effectiveAt: String? = nil
    var schedulePrecision: String? = nil
    var scheduleBasis: String? = nil
    var postID: String = "123"

    var json: String {
        let effectiveValue = effectiveAt.map { "\"\($0)\"" } ?? "null"
        var extra = ""
        if let resetType {
            extra += ",\n          \"resetType\": \"\(resetType)\""
        }
        if let schedulePrecision {
            extra += ",\n          \"schedulePrecision\": \"\(schedulePrecision)\""
        }
        if let scheduleBasis {
            extra += ",\n          \"scheduleBasis\": \"\(scheduleBasis)\""
        }
        return """
        {
          "kind": "\(kind)",
          "announcedAt": "\(announcedAt)",
          "effectiveAt": \(effectiveValue)\(extra),
          "scope": {"plans": ["all"], "windows": ["weekly"]},
          "source": {
            "handle": "thsottiaux",
            "postId": "\(postID)",
            "url": "https://x.com/thsottiaux/status/\(postID)"
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
            switch resetType {
            case "banked":
                "Explicit Codex reset-bank credit announcement."
            case "global_and_banked":
                "Explicit Codex global reset and reset-bank credit announcement."
            default:
                "Explicit Codex quota reset announcement."
            }
        case "reset_scheduled":
            if scheduleBasis == "contextual_inference" {
                switch resetType {
                case "banked":
                    "High-probability Codex reset-bank credit preview inferred from context."
                case "global_and_banked":
                    "High-probability Codex global reset and reset-bank credit preview inferred from context."
                default:
                    "High-probability Codex quota reset preview inferred from context."
                }
            } else {
                switch resetType {
                case "banked":
                    "Explicit Codex reset-bank credit schedule."
                case "global_and_banked":
                    "Explicit Codex global reset and reset-bank credit schedule."
                default:
                    "Explicit Codex quota reset schedule."
                }
            }
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
    var resetTimelineJSON: String?
    var lastSuccessfulCheckAt: String? = "2026-07-28T12:00:00Z"
    var monitorStatus = "ok"
    var errorCode: String?
    var now: Date
    var calendar: Calendar = resetStatusUTCCalendar

    init(event: ResetStatusEventFixture, now: Date) {
        self.eventsJSON = event.json
        self.resetTimelineJSON = nil
        self.now = now
    }

    init(eventsJSON: String = "", now: Date) {
        self.eventsJSON = eventsJSON
        self.resetTimelineJSON = nil
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

    func withTimeline(_ json: String) -> ResetStatusFeedFixture {
        var copy = self
        copy.resetTimelineJSON = json
        return copy
    }

    func decode() throws -> RateLimitResetTodaySnapshot {
        let lastSuccessValue = lastSuccessfulCheckAt.map { "\"\($0)\"" } ?? "null"
        let errorValue = errorCode.map { "\"\($0)\"" } ?? "null"
        let timelineField = resetTimelineJSON.map { ",\n          \"resetTimeline\": \($0)" } ?? ""
        let data = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-28T12:00:00Z",
          "lastSuccessfulCheckAt": \(lastSuccessValue),
          "monitor": {"status": "\(monitorStatus)", "errorCode": \(errorValue)},
          "events": [\(eventsJSON)]\(timelineField)
        }
        """.data(using: .utf8)!
        return try RateLimitResetTodaySnapshot.decode(
            from: data,
            now: now,
            calendar: calendar)
    }
}

func resetStatusEmptyTimelineJSON(
    nextScheduleJSON: String? = nil,
    recentNonCompletedPostId: String? = nil,
    fulfilledJSON: String = "",
    manualJSON: String = "",
    suppressedJSON: String = "") -> String
{
    let next = nextScheduleJSON ?? "null"
    let recent = recentNonCompletedPostId.map { "\"\($0)\"" } ?? "null"
    var extra = ""
    if !manualJSON.isEmpty {
        extra += ",\n          \"manualCompletions\": [\(manualJSON)]"
    }
    if !suppressedJSON.isEmpty {
        extra += ",\n          \"suppressedPostIds\": [\(suppressedJSON)]"
    }
    return """
    {
      "nextSchedule": \(next),
      "recentNonCompletedPostId": \(recent),
      "fulfilledSchedules": [\(fulfilledJSON)]\(extra)
    }
    """
}

func resetStatusDate(_ value: String) throws -> Date {
    try Date(value, strategy: .iso8601)
}

let resetStatusUTCCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()
