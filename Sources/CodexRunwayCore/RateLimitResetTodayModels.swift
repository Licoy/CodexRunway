import Foundation

public enum RateLimitResetTodayState: String, Sendable, Equatable {
    case yes
    case no
    case unknown
}

public enum RateLimitResetTodayMonitorStatus: String, Decodable, Sendable, Equatable {
    case ok
    case degraded
}

public struct RateLimitResetTodayMonitor: Decodable, Sendable, Equatable {
    public var status: RateLimitResetTodayMonitorStatus
    public var errorCode: String?

    public init(status: RateLimitResetTodayMonitorStatus, errorCode: String? = nil) {
        self.status = status
        self.errorCode = errorCode
    }
}

public enum RateLimitResetTodayEventKind: String, Decodable, Sendable, Equatable {
    case resetCompleted = "reset_completed"
    case resetScheduled = "reset_scheduled"
    case bankedReset = "banked_reset"
    case limitIncrease = "limit_increase"
    case uncertain
}

public struct RateLimitResetTodayScope: Decodable, Sendable, Equatable {
    public var plans: [String]
    public var windows: [String]

    public init(plans: [String], windows: [String]) {
        self.plans = plans
        self.windows = windows
    }
}

public struct RateLimitResetTodaySource: Decodable, Sendable, Equatable {
    public var handle: String
    public var postID: String
    public var url: URL

    private enum CodingKeys: String, CodingKey {
        case handle
        case postID = "postId"
        case url
    }

    public init(handle: String, postID: String, url: URL) {
        self.handle = handle
        self.postID = postID
        self.url = url
    }
}

public struct RateLimitResetTodayEvent: Decodable, Sendable, Equatable {
    public var kind: RateLimitResetTodayEventKind
    public var announcedAt: Date
    public var effectiveAt: Date? = nil
    public var scope: RateLimitResetTodayScope
    public var source: RateLimitResetTodaySource
    public var confidence: Double
    public var rationale: String

}

public struct RateLimitResetTodaySnapshot: Sendable, Equatable {
    public static let staleAfter: TimeInterval = 30 * 3_600

    public var schemaVersion: Int
    public var generatedAt: Date
    public var lastSuccessfulCheckAt: Date?
    public var monitor: RateLimitResetTodayMonitor
    public var events: [RateLimitResetTodayEvent]
    public private(set) var state: RateLimitResetTodayState
    public var fetchedAt: Date

    private var stateOverride: RateLimitResetTodayState?

    /// Compatibility initializer used by app-level service fixtures.
    public init(state: RateLimitResetTodayState, fetchedAt: Date = Date()) {
        self.schemaVersion = 1
        self.generatedAt = fetchedAt
        self.lastSuccessfulCheckAt = state == .unknown ? nil : fetchedAt
        self.monitor = RateLimitResetTodayMonitor(
            status: state == .unknown ? .degraded : .ok,
            errorCode: state == .unknown ? "mock_unavailable" : nil)
        self.events = []
        self.state = state
        self.fetchedAt = fetchedAt
        self.stateOverride = state
    }

    init(
        response: RateLimitResetTodayResponse,
        now: Date,
        calendar: Calendar)
    {
        self.schemaVersion = response.schemaVersion
        self.generatedAt = response.generatedAt
        self.lastSuccessfulCheckAt = response.lastSuccessfulCheckAt
        self.monitor = response.monitor
        self.events = response.events
        self.state = .unknown
        self.fetchedAt = now
        self.stateOverride = nil
        self.state = resolvedState(now: now, calendar: calendar)
    }

    /// Re-evaluates the result at a supplied time and calendar, for local-day boundaries.
    public func resolvedState(
        now: Date = Date(),
        calendar: Calendar = .current) -> RateLimitResetTodayState
    {
        if let stateOverride { return stateOverride }
        guard monitor.status == .ok, let lastSuccessfulCheckAt,
              now.timeIntervalSince(lastSuccessfulCheckAt) <= Self.staleAfter
        else {
            return .unknown
        }
        // Confirmed same-day resets win over uncertain commentary/replies.
        let hasEffectiveResetToday = events.contains { event in
            guard let occurredAt = event.resetOccurrenceAt, occurredAt <= now else {
                return false
            }
            return calendar.isDate(occurredAt, inSameDayAs: now)
        }
        if hasEffectiveResetToday {
            return .yes
        }
        if events.contains(where: {
            $0.kind == .uncertain && calendar.isDate($0.announcedAt, inSameDayAs: now)
        }) {
            return .unknown
        }
        return .no
    }

    public var latestEvent: RateLimitResetTodayEvent? {
        events.max { $0.announcedAt < $1.announcedAt }
    }

    public var evidenceURL: URL? {
        latestEvent?.source.url
    }

    /// Maps the event kind to app-owned copy; feed text is never shown directly.
    public func evidenceLine(l10n: L10n) -> String? {
        guard let kind = latestEvent?.kind else { return nil }
        let key: L10nKey = switch kind {
        case .resetCompleted:
            .rateLimitResetTodayEvidenceResetCompleted
        case .resetScheduled:
            .rateLimitResetTodayEvidenceResetScheduled
        case .bankedReset:
            .rateLimitResetTodayEvidenceBankedReset
        case .limitIncrease:
            .rateLimitResetTodayEvidenceLimitIncrease
        case .uncertain:
            .rateLimitResetTodayEvidenceUncertain
        }
        return l10n.text(key)
    }

    public func latestResetAt(now: Date = Date()) -> Date? {
        events.compactMap { event -> Date? in
            guard let occurredAt = event.resetOccurrenceAt, occurredAt <= now else { return nil }
            return occurredAt
        }
        .max()
    }

    public enum DevMockKind: String, Sendable, Equatable {
        case yes
        case no
        case unknown

        public static func parse(_ raw: String) -> DevMockKind? {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "y", "1", "true":
                return .yes
            case "no", "n", "0", "false":
                return .no
            case "unknown":
                return .unknown
            default:
                return nil
            }
        }
    }

    public static func devMock(
        state: RateLimitResetTodayState,
        now: Date = Date()) -> RateLimitResetTodaySnapshot
    {
        let kind: DevMockKind = switch state {
        case .yes: .yes
        case .no: .no
        case .unknown: .unknown
        }
        return devMock(kind: kind, now: now)
    }

    public static func devMock(
        kind: DevMockKind,
        now: Date = Date()) -> RateLimitResetTodaySnapshot
    {
        let monitor = RateLimitResetTodayMonitor(
            status: kind == .unknown ? .degraded : .ok,
            errorCode: kind == .unknown ? "request_failed" : nil)
        let events: [RateLimitResetTodayEvent]
        if kind == .yes {
            events = [
                RateLimitResetTodayEvent(
                    kind: .resetCompleted,
                    announcedAt: now,
                    scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly", "five_hour"]),
                    source: RateLimitResetTodaySource(
                        handle: "thsottiaux",
                        postID: "2079433708986319143",
                        url: URL(string: "https://x.com/thsottiaux/status/2079433708986319143")!),
                    confidence: 0.98,
                    rationale: "Explicit Codex quota reset announcement."),
            ]
        } else {
            events = []
        }
        let response = RateLimitResetTodayResponse(
            schemaVersion: 1,
            generatedAt: now,
            lastSuccessfulCheckAt: kind == .unknown ? nil : now,
            monitor: monitor,
            events: events)
        return RateLimitResetTodaySnapshot(
            response: response,
            now: now,
            calendar: .current)
    }
}

private extension RateLimitResetTodayEvent {
    var resetOccurrenceAt: Date? {
        switch kind {
        case .resetCompleted:
            effectiveAt ?? announcedAt
        case .resetScheduled:
            effectiveAt
        case .bankedReset, .limitIncrease, .uncertain:
            nil
        }
    }
}
