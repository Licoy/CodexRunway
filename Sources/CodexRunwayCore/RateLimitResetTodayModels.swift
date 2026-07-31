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
    ///
    /// "Yes" means the local calendar day has a reset — either already effective
    /// or still scheduled later today. Multiple same-day resets are allowed.
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
        // Same-day schedule or completed reset wins over uncertain commentary.
        if hasResetOnLocalDay(now: now, calendar: calendar) {
            return .yes
        }
        if events.contains(where: {
            $0.kind == .uncertain && calendar.isDate($0.announcedAt, inSameDayAs: now)
        }) {
            return .unknown
        }
        return .no
    }

    /// True when a reset has already taken effect on the local calendar day.
    public func hasAlreadyEffectiveResetToday(
        now: Date = Date(),
        calendar: Calendar = .current) -> Bool
    {
        events.contains { event in
            guard let occurredAt = event.resetOccurrenceAt, occurredAt <= now else {
                return false
            }
            return calendar.isDate(occurredAt, inSameDayAs: now)
        }
    }

    /// True when any reset (completed or scheduled) lands on the local calendar day.
    public func hasResetOnLocalDay(
        now: Date = Date(),
        calendar: Calendar = .current) -> Bool
    {
        if hasAlreadyEffectiveResetToday(now: now, calendar: calendar) {
            return true
        }
        if let next = nextScheduledReset(now: now),
           calendar.isDate(next.effectiveAt, inSameDayAs: now)
        {
            return true
        }
        return false
    }

    public var latestEvent: RateLimitResetTodayEvent? {
        events.max { $0.announcedAt < $1.announcedAt }
    }

    /// Prefer the event that best explains the current answer, not merely the newest tweet.
    /// When multiple same-day resets exist, the next upcoming schedule outranks past ones.
    public func primaryEvidenceEvent(
        now: Date = Date(),
        calendar: Calendar = .current) -> RateLimitResetTodayEvent?
    {
        switch resolvedState(now: now, calendar: calendar) {
        case .yes:
            if let next = nextScheduledReset(now: now),
               calendar.isDate(next.effectiveAt, inSameDayAs: now)
            {
                return next.event
            }
            return events
                .filter { event in
                    guard let occurredAt = event.resetOccurrenceAt, occurredAt <= now else {
                        return false
                    }
                    return calendar.isDate(occurredAt, inSameDayAs: now)
                }
                .max { $0.announcedAt < $1.announcedAt }
                ?? latestEvent
        case .no:
            return nextScheduledReset(now: now)?.event ?? latestEvent
        case .unknown:
            return events
                .filter { $0.kind == .uncertain && calendar.isDate($0.announcedAt, inSameDayAs: now) }
                .max { $0.announcedAt < $1.announcedAt }
                ?? latestEvent
        }
    }

    public func evidenceURL(
        now: Date = Date(),
        calendar: Calendar = .current) -> URL?
    {
        primaryEvidenceEvent(now: now, calendar: calendar)?.source.url
            ?? latestEvent?.source.url
    }

    /// Maps the event kind to app-owned copy; feed text is never shown directly.
    public func evidenceLine(
        l10n: L10n,
        now: Date = Date(),
        calendar: Calendar = .current) -> String?
    {
        guard let event = primaryEvidenceEvent(now: now, calendar: calendar) else { return nil }
        let key: L10nKey = switch event.kind {
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

    /// Next future `reset_scheduled` effective time, if any.
    public func nextScheduledReset(now: Date = Date()) -> (effectiveAt: Date, event: RateLimitResetTodayEvent)? {
        var best: (effectiveAt: Date, event: RateLimitResetTodayEvent)?
        for event in events {
            guard event.kind == .resetScheduled, let when = event.effectiveAt, when > now else {
                continue
            }
            if best == nil || when < best!.effectiveAt {
                best = (when, event)
            }
        }
        return best
    }

    public func scopeSummary(
        for event: RateLimitResetTodayEvent,
        l10n: L10n) -> String?
    {
        var parts: [String] = []
        let plans = event.scope.plans
            .map { planLabel($0, l10n: l10n) }
            .filter { !$0.isEmpty }
        let windows = event.scope.windows
            .map { windowLabel($0, l10n: l10n) }
            .filter { !$0.isEmpty }
        if !plans.isEmpty {
            parts.append("\(l10n.text(.rateLimitResetTodayPlans)): \(plans.joined(separator: ", "))")
        }
        if !windows.isEmpty {
            parts.append("\(l10n.text(.rateLimitResetTodayWindows)): \(windows.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func planLabel(_ plan: String, l10n: L10n) -> String {
        switch plan {
        case "all": return l10n.text(.rateLimitResetTodayPlanAll)
        case "free": return l10n.text(.rateLimitResetTodayPlanFree)
        case "plus": return l10n.text(.rateLimitResetTodayPlanPlus)
        case "pro": return l10n.text(.rateLimitResetTodayPlanPro)
        case "team": return l10n.text(.rateLimitResetTodayPlanTeam)
        case "business": return l10n.text(.rateLimitResetTodayPlanBusiness)
        case "enterprise": return l10n.text(.rateLimitResetTodayPlanEnterprise)
        case "unknown": return l10n.text(.rateLimitResetTodayPlanUnknown)
        default: return plan
        }
    }

    private func windowLabel(_ window: String, l10n: L10n) -> String {
        switch window {
        case "weekly": return l10n.text(.rateLimitResetTodayWindowWeekly)
        case "five_hour": return l10n.text(.rateLimitResetTodayWindowFiveHour)
        case "unknown": return l10n.text(.rateLimitResetTodayWindowUnknown)
        default: return window
        }
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
