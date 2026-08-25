import Foundation

extension RateLimitResetTodaySnapshot {
    public static func decode(
        from data: Data,
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) throws -> RateLimitResetTodaySnapshot
    {
        let decoder = JSONDecoder()
        // Feed timestamps are absolute instants (RFC 3339 with offset / Z).
        // Parse via ISO8601DateFormatter so fractional seconds work and bare
        // local wall-clock strings (no timezone) are rejected — treating those
        // as local would shift "today" and fire wrong reset notifications.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = RunwayDates.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an RFC 3339 timestamp with timezone offset.")
            }
            return date
        }
        let response = try decoder.decode(RateLimitResetTodayResponse.self, from: data)
        guard response.schemaVersion == 1 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unsupported reset-status schema version."))
        }
        try validate(response)
        return RateLimitResetTodaySnapshot(
            response: response,
            now: now,
            calendar: calendar)
    }

    private static func validate(_ response: RateLimitResetTodayResponse) throws {
        switch response.monitor.status {
        case .ok:
            guard response.monitor.errorCode == nil else {
                throw invalidPayload("A healthy monitor must not publish an error code.")
            }
        case .degraded:
            guard let errorCode = response.monitor.errorCode,
                  Self.monitorErrorCodes.contains(errorCode)
            else {
                throw invalidPayload("A degraded monitor must publish an error code.")
            }
        }

        guard response.events.count <= 50 else {
            throw invalidPayload("The reset-status feed contains too many events.")
        }
        for event in response.events {
            try validate(event)
        }
        if let timeline = response.resetTimeline {
            try validate(timeline)
        }
    }

    private static func validate(_ timeline: RateLimitResetTimeline) throws {
        if let next = timeline.nextSchedule {
            try validate(next)
            guard next.kind == .resetScheduled else {
                throw invalidPayload("nextSchedule must be a scheduled reset.")
            }
            guard next.resetType.includes(.global) else {
                throw invalidPayload("nextSchedule must include a global reset.")
            }
        }
        if let postID = timeline.recentNonCompletedPostId {
            try validatePostID(postID, label: "recentNonCompletedPostId")
        }
        var fulfilledIDs = Set<String>()
        for entry in timeline.fulfilledSchedules {
            try validate(entry.schedule)
            guard entry.schedule.kind == .resetScheduled else {
                throw invalidPayload("A fulfilled schedule must contain a scheduled event.")
            }
            try validateEventID(entry.completionPostID, label: "completionPostId")
            guard entry.visibleUntil >= entry.completedAt else {
                throw invalidPayload("Fulfilled schedule visibility cannot end before completion.")
            }
            try validate(entry.window)
            let scheduleID = entry.schedule.source.postID
            guard fulfilledIDs.insert(scheduleID).inserted else {
                throw invalidPayload("Fulfilled schedules must have unique post IDs.")
            }
        }
        for entry in timeline.fulfilledBanked {
            try validate(entry.banked)
            guard entry.banked.kind == .bankedReset else {
                throw invalidPayload("A fulfilled banked origin must contain a banked reset event.")
            }
            try validateEventID(entry.completionPostID, label: "completionPostId")
            guard entry.visibleUntil >= entry.completedAt else {
                throw invalidPayload("Fulfilled banked visibility cannot end before completion.")
            }
        }
        var manualIDs = Set<String>()
        for item in timeline.manualCompletions {
            try validate(item)
            guard manualIDs.insert(item.id).inserted else {
                throw invalidPayload("Manual completions must have unique IDs.")
            }
        }
        var suppressed = Set<String>()
        for postID in timeline.suppressedPostIds {
            try validatePostID(postID, label: "suppressedPostIds")
            guard suppressed.insert(postID).inserted else {
                throw invalidPayload("Suppressed post IDs must be unique.")
            }
        }
    }

    private static func validate(_ item: RateLimitResetManualCompletion) throws {
        guard item.id.hasPrefix("manual:") else {
            throw invalidPayload("Manual completion IDs must start with manual:.")
        }
        guard item.visibleUntil >= item.completedAt else {
            throw invalidPayload("Manual completion visibility cannot end before completion.")
        }
        guard item.fulfillmentOrigin == "manual" else {
            throw invalidPayload("Manual completions must use fulfillmentOrigin manual.")
        }
        try validatePostID(item.representativePostID, label: "representativePostId")
        guard !item.schedulePostIDs.isEmpty,
              Set(item.schedulePostIDs).count == item.schedulePostIDs.count
        else {
            throw invalidPayload("Manual completion schedule post IDs must be unique and non-empty.")
        }
        for postID in item.schedulePostIDs {
            try validatePostID(postID, label: "schedulePostIds")
        }
        guard item.schedulePostIDs.contains(item.representativePostID) else {
            throw invalidPayload("Manual completion representative must be one of its schedules.")
        }
        guard item.schedules.map(\.source.postID) == item.schedulePostIDs else {
            throw invalidPayload("Manual completion schedules must match schedulePostIds.")
        }
        for event in item.schedules {
            try validate(event)
            guard event.kind == .resetScheduled else {
                throw invalidPayload("Manual completion schedules must be scheduled events.")
            }
        }
    }

    private static func validate(_ window: RateLimitResetPublishedWindow) throws {
        switch window.precision {
        case .datetime:
            guard window.endAt == window.startAt else {
                throw invalidPayload("A datetime reset window must be a single instant.")
            }
        case .date:
            guard window.endAt > window.startAt else {
                throw invalidPayload("A date reset window must span a calendar day.")
            }
        }
    }

    private static func validate(_ event: RateLimitResetTodayEvent) throws {
        guard event.confidence.isFinite, 0...1 ~= event.confidence else {
            throw invalidPayload("Event confidence must be between zero and one.")
        }
        try validate(event.source, kind: event.kind)
        guard !event.text.isEmpty else {
            throw invalidPayload("Event text must be a non-empty original post body.")
        }
        guard event.acceptedRationales.contains(event.rationale) else {
            throw invalidPayload("Event rationale must be the derived explanation for its kind.")
        }
        switch event.kind {
        case .resetCompleted:
            guard event.schedulePrecision == nil, event.scheduleBasis == nil else {
                throw invalidPayload("Schedule metadata is only allowed for scheduled events.")
            }
        case .resetScheduled:
            guard event.effectiveAt != nil else {
                throw invalidPayload("A scheduled reset must include its effective time.")
            }
        case .bankedReset:
            guard event.resetType != .globalAndBanked else {
                throw invalidPayload("A banked reset origin cannot combine reset types.")
            }
            guard event.effectiveAt == nil else {
                throw invalidPayload("This event kind cannot include an effective time.")
            }
            guard event.schedulePrecision == nil, event.scheduleBasis == nil else {
                throw invalidPayload("Schedule metadata is only allowed for scheduled events.")
            }
        case .limitIncrease, .uncertain:
            guard event.resetType == .global else {
                throw invalidPayload("This event kind cannot publish a reset type.")
            }
            guard event.effectiveAt == nil else {
                throw invalidPayload("This event kind cannot include an effective time.")
            }
            guard event.schedulePrecision == nil, event.scheduleBasis == nil else {
                throw invalidPayload("Schedule metadata is only allowed for scheduled events.")
            }
        }
    }

    private static func validate(
        _ source: RateLimitResetTodaySource,
        kind: RateLimitResetTodayEventKind) throws
    {
        if source.isOperator {
            guard kind == .resetCompleted else {
                throw invalidPayload("Operator events must be completed resets.")
            }
            guard RateLimitResetTodaySource.isOperatorEventID(source.postID),
                  source.handle == nil,
                  source.url == nil
            else {
                throw invalidPayload("Operator event source requires an op_ event id without handle or URL.")
            }
            return
        }
        guard !RateLimitResetTodaySource.isOperatorEventID(source.postID),
              RateLimitResetTodaySource.isXPostID(source.postID),
              source.handle == "thsottiaux",
              let url = source.url
        else {
            throw invalidPayload("Event source must identify a valid @thsottiaux X post.")
        }
        let sourcePath = url.pathComponents.filter { $0 != "/" }
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "x.com",
              sourcePath.count == 3,
              sourcePath[0].caseInsensitiveCompare("thsottiaux") == .orderedSame,
              sourcePath[1] == "status",
              sourcePath[2] == source.postID
        else {
            throw invalidPayload("Event source must identify a valid @thsottiaux X post.")
        }
    }

    private static func validatePostID(_ postID: String, label: String) throws {
        guard RateLimitResetTodaySource.isXPostID(postID) else {
            throw invalidPayload("\(label) must be a numeric X post ID.")
        }
    }

    private static func validateEventID(_ postID: String, label: String) throws {
        guard RateLimitResetTodaySource.isEventID(postID) else {
            throw invalidPayload("\(label) must be a numeric X post ID or operator event id.")
        }
    }

    private static func invalidPayload(_ description: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
    }

    private static var monitorErrorCodes: Set<String> {
        ["configuration_error", "request_failed", "invalid_response", "uncited_source"]
    }
}

private extension RateLimitResetTodayEvent {
    /// Schema enum rationales for each kind. `uncertain` accepts the current
    /// canonical string and one legacy wording during feed transition.
    var acceptedRationales: Set<String> {
        switch kind {
        case .resetCompleted:
            if source.isOperator {
                switch resetType {
                case .global:
                    ["Operator-confirmed Codex quota reset without an X announcement."]
                case .banked:
                    ["Operator-confirmed Codex reset-bank credit without an X announcement."]
                case .globalAndBanked:
                    ["Operator-confirmed Codex global reset and reset-bank credit without an X announcement."]
                }
            } else {
                switch resetType {
                case .global:
                    ["Explicit Codex quota reset announcement."]
                case .banked:
                    ["Explicit Codex reset-bank credit announcement."]
                case .globalAndBanked:
                    ["Explicit Codex global reset and reset-bank credit announcement."]
                }
            }
        case .resetScheduled:
            if scheduleBasis == .contextualInference {
                switch resetType {
                case .global:
                    ["High-probability Codex quota reset preview inferred from context."]
                case .banked:
                    ["High-probability Codex reset-bank credit preview inferred from context."]
                case .globalAndBanked:
                    ["High-probability Codex global reset and reset-bank credit preview inferred from context."]
                }
            } else {
                switch resetType {
                case .global:
                    ["Explicit Codex quota reset schedule."]
                case .banked:
                    ["Explicit Codex reset-bank credit schedule."]
                case .globalAndBanked:
                    ["Explicit Codex global reset and reset-bank credit schedule."]
                }
            }
        case .bankedReset:
            ["Banked reset announcement; not a completed reset."]
        case .limitIncrease:
            ["Quota limit increase announcement; not a reset."]
        case .uncertain:
            [
                "Not a clear reset signal.",
                // Legacy feed wording retained briefly for cached/old payloads.
                "Relevant announcement could not be classified safely.",
            ]
        }
    }
}

struct RateLimitResetTodayResponse: Decodable {
    var schemaVersion: Int
    var generatedAt: Date
    var lastSuccessfulCheckAt: Date?
    var monitor: RateLimitResetTodayMonitor
    var events: [RateLimitResetTodayEvent]
    var resetTimeline: RateLimitResetTimeline?

    init(
        schemaVersion: Int,
        generatedAt: Date,
        lastSuccessfulCheckAt: Date?,
        monitor: RateLimitResetTodayMonitor,
        events: [RateLimitResetTodayEvent],
        resetTimeline: RateLimitResetTimeline? = nil)
    {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.monitor = monitor
        self.events = events
        self.resetTimeline = resetTimeline
    }
}
