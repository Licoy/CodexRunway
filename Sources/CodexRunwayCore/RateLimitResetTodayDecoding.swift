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
            guard event.confidence.isFinite, 0...1 ~= event.confidence else {
                throw invalidPayload("Event confidence must be between zero and one.")
            }
            let sourcePath = event.source.url.pathComponents.filter { $0 != "/" }
            guard event.source.handle == "thsottiaux",
                  !event.source.postID.isEmpty,
                  event.source.postID.count <= 30,
                  event.source.postID.allSatisfy(\.isNumber),
                  event.source.url.scheme?.lowercased() == "https",
                  event.source.url.host?.lowercased() == "x.com",
                  sourcePath.count == 3,
                  sourcePath[0].caseInsensitiveCompare(event.source.handle) == .orderedSame,
                  sourcePath[1] == "status",
                  sourcePath[2] == event.source.postID
            else {
                throw invalidPayload("Event source must identify a valid @thsottiaux X post.")
            }
            guard event.rationale == event.kind.derivedRationale
            else {
                throw invalidPayload("Event rationale must be the derived explanation for its kind.")
            }
            switch event.kind {
            case .resetCompleted:
                break
            case .resetScheduled:
                guard event.effectiveAt != nil else {
                    throw invalidPayload("A scheduled reset must include its effective time.")
                }
            case .bankedReset, .limitIncrease, .uncertain:
                guard event.effectiveAt == nil else {
                    throw invalidPayload("This event kind cannot include an effective time.")
                }
            }
        }
    }

    private static func invalidPayload(_ description: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
    }

    private static var monitorErrorCodes: Set<String> {
        ["configuration_error", "request_failed", "invalid_response", "uncited_source"]
    }
}

private extension RateLimitResetTodayEventKind {
    var derivedRationale: String {
        switch self {
        case .resetCompleted:
            "Explicit Codex quota reset announcement."
        case .resetScheduled:
            "Explicit Codex quota reset schedule."
        case .bankedReset:
            "Banked reset announcement; not a completed reset."
        case .limitIncrease:
            "Quota limit increase announcement; not a reset."
        case .uncertain:
            "Relevant announcement could not be classified safely."
        }
    }
}

struct RateLimitResetTodayResponse: Decodable {
    var schemaVersion: Int
    var generatedAt: Date
    var lastSuccessfulCheckAt: Date?
    var monitor: RateLimitResetTodayMonitor
    var events: [RateLimitResetTodayEvent]
}
