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
    /// Original subject post text from the feed. Validated on decode; UI uses app-owned copy.
    public var text: String

    public init(
        kind: RateLimitResetTodayEventKind,
        announcedAt: Date,
        effectiveAt: Date? = nil,
        scope: RateLimitResetTodayScope,
        source: RateLimitResetTodaySource,
        confidence: Double,
        rationale: String,
        text: String)
    {
        self.kind = kind
        self.announcedAt = announcedAt
        self.effectiveAt = effectiveAt
        self.scope = scope
        self.source = source
        self.confidence = confidence
        self.rationale = rationale
        self.text = text
    }
}

public struct RateLimitResetScheduleWindow: Sendable, Equatable {
    public var startAt: Date
    public var endAt: Date
    public var isRange: Bool

    public init(startAt: Date, endAt: Date, isRange: Bool) {
        self.startAt = startAt
        self.endAt = endAt
        self.isRange = isRange
    }
}

public struct RateLimitResetTodaySnapshot: Sendable, Equatable {
    public static let staleAfter: TimeInterval = 30 * 3_600

    /// Gregorian local-day calendar using the device timezone.
    ///
    /// Feed timestamps are absolute UTC instants. "Today" must be the viewer's
    /// local Gregorian calendar day — never the UTC date string, and never a
    /// non-Gregorian preferred calendar (which can shift day boundaries).
    public static var localDayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

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
    ///
    /// - Important: `announcedAt` / `effectiveAt` are absolute UTC instants from the
    ///   feed. Same-day checks convert them through `calendar.timeZone` (default:
    ///   the device local zone). Never treat the ISO date prefix as a local day.
    public func resolvedState(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> RateLimitResetTodayState
    {
        if let stateOverride { return stateOverride }
        // Only degraded / missing / stale monitor data is "unknown".
        // A healthy feed with only uncertain (or empty) events means "no" —
        // matching the hosted status page: 是 / 否, never "unavailable" for clear
        // "not a reset signal" commentary.
        guard monitor.status == .ok, let lastSuccessfulCheckAt,
              now.timeIntervalSince(lastSuccessfulCheckAt) <= Self.staleAfter
        else {
            return .unknown
        }
        if hasResetOnLocalDay(now: now, calendar: calendar) {
            return .yes
        }
        return .no
    }

    /// True when the best explanation for "no" is same-day uncertain commentary
    /// (website: "今日无明确的重置信号"), not merely an empty event log.
    public func hasUncertainNoSignalToday(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> Bool
    {
        guard resolvedState(now: now, calendar: calendar) == .no else { return false }
        return events.contains {
            $0.kind == .uncertain && calendar.isDate($0.announcedAt, inSameDayAs: now)
        }
    }

    /// True when a reset has already taken effect on the local calendar day.
    public func hasAlreadyEffectiveResetToday(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> Bool
    {
        events.contains { event in
            guard event.kind == .resetCompleted else { return false }
            guard let occurredAt = event.resetOccurrenceAt, occurredAt <= now else {
                return false
            }
            return calendar.isDate(occurredAt, inSameDayAs: now)
        }
    }

    /// True when any reset (completed or scheduled) lands on the local calendar day.
    public func hasResetOnLocalDay(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> Bool
    {
        if hasAlreadyEffectiveResetToday(now: now, calendar: calendar) {
            return true
        }
        // Prefer same-day schedules even when an earlier future schedule falls tomorrow.
        return nextScheduledReset(onLocalDayOf: now, calendar: calendar) != nil
    }

    public var latestEvent: RateLimitResetTodayEvent? {
        events.max { $0.announcedAt < $1.announcedAt }
    }

    /// Prefer the event that best explains the current answer, not merely the newest tweet.
    /// When multiple same-day resets exist, the next upcoming *same-day* schedule outranks past ones.
    public func primaryEvidenceEvent(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> RateLimitResetTodayEvent?
    {
        switch resolvedState(now: now, calendar: calendar) {
        case .yes:
            if let nextSameDay = nextScheduledReset(onLocalDayOf: now, calendar: calendar) {
                return nextSameDay.event
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
            // Prefer same-day non-reset commentary that explains today's "no".
            if let sameDayCommentary = events
                .filter({
                    calendar.isDate($0.announcedAt, inSameDayAs: now)
                        && ($0.kind == .uncertain
                            || $0.kind == .bankedReset
                            || $0.kind == .limitIncrease)
                })
                .max(by: { $0.announcedAt < $1.announcedAt })
            {
                return sameDayCommentary
            }
            return nextScheduledReset(now: now)?.event ?? latestEvent
        case .unknown:
            return latestEvent
        }
    }

    public func evidenceURL(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> URL?
    {
        primaryEvidenceEvent(now: now, calendar: calendar)?.source.url
            ?? latestEvent?.source.url
    }

    /// Maps the event kind to app-owned copy; feed text is never shown directly.
    public func evidenceLine(
        l10n: L10n,
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> String?
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

    /// Next pending `reset_scheduled` window, if any.
    public func nextScheduledReset(now: Date = Date())
        -> (effectiveAt: Date, effectiveUntil: Date, isRange: Bool, event: RateLimitResetTodayEvent)?
    {
        nextScheduledReset(after: now, matchingLocalDayOf: nil, calendar: nil)
    }

    /// Next future schedule that lands on the same local day as `now`.
    public func nextScheduledReset(
        onLocalDayOf now: Date,
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar)
        -> (effectiveAt: Date, effectiveUntil: Date, isRange: Bool, event: RateLimitResetTodayEvent)?
    {
        nextScheduledReset(after: now, matchingLocalDayOf: now, calendar: calendar)
    }

    public func scheduledResetWindow(for event: RateLimitResetTodayEvent) -> RateLimitResetScheduleWindow? {
        guard event.kind == .resetScheduled, let startAt = event.effectiveAt else { return nil }
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let components = sourceCalendar.dateComponents([.hour, .minute, .second], from: startAt)
        let isDateOnly = components.hour == 0 && components.minute == 0 && components.second == 0
        guard isDateOnly else {
            return RateLimitResetScheduleWindow(startAt: startAt, endAt: startAt, isRange: false)
        }
        let endAt = sourceCalendar.date(byAdding: .day, value: 1, to: startAt)!
            .addingTimeInterval(-60)
        return RateLimitResetScheduleWindow(startAt: startAt, endAt: endAt, isRange: true)
    }

    private func nextScheduledReset(
        after now: Date,
        matchingLocalDayOf day: Date?,
        calendar: Calendar?)
        -> (effectiveAt: Date, effectiveUntil: Date, isRange: Bool, event: RateLimitResetTodayEvent)?
    {
        var best: (
            effectiveAt: Date,
            effectiveUntil: Date,
            isRange: Bool,
            event: RateLimitResetTodayEvent)?
        for event in events {
            guard let window = scheduledResetWindow(for: event), window.endAt > now else { continue }
            if let day, let calendar, !intersectsLocalDay(window, day: day, calendar: calendar) {
                continue
            }
            if best == nil || window.startAt < best!.effectiveAt {
                best = (window.startAt, window.endAt, window.isRange, event)
            }
        }
        return best
    }

    private func intersectsLocalDay(
        _ window: RateLimitResetScheduleWindow,
        day: Date,
        calendar: Calendar) -> Bool
    {
        guard let dayInterval = calendar.dateInterval(of: .day, for: day) else { return false }
        return window.endAt >= dayInterval.start && window.startAt < dayInterval.end
    }

    public func scopeSummary(
        for event: RateLimitResetTodayEvent,
        l10n: L10n) -> String?
    {
        // Pure "unknown" scope is noise on the status card; only show real plan/window labels.
        let plans = event.scope.plans
            .filter { $0 != "unknown" }
            .map { planLabel($0, l10n: l10n) }
            .filter { !$0.isEmpty }
        let windows = event.scope.windows
            .filter { $0 != "unknown" }
            .map { windowLabel($0, l10n: l10n) }
            .filter { !$0.isEmpty }
        var parts: [String] = []
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
        case scheduled
        case unknown

        public static func parse(_ raw: String) -> DevMockKind? {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "y", "1", "true":
                return .yes
            case "no", "n", "0", "false":
                return .no
            case "scheduled", "schedule":
                return .scheduled
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
                    rationale: "Explicit Codex quota reset announcement.",
                    text: "I have reset usage limits for Codex."),
            ]
        } else if kind == .scheduled {
            var sourceCalendar = Calendar(identifier: .gregorian)
            sourceCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            let today = sourceCalendar.startOfDay(for: now)
            let effectiveAt = sourceCalendar.date(byAdding: .day, value: 1, to: today)!
            events = [
                RateLimitResetTodayEvent(
                    kind: .resetScheduled,
                    announcedAt: now,
                    effectiveAt: effectiveAt,
                    scope: RateLimitResetTodayScope(plans: ["all"], windows: ["weekly"]),
                    source: RateLimitResetTodaySource(
                        handle: "thsottiaux",
                        postID: "2086189414292865249",
                        url: URL(string: "https://x.com/thsottiaux/status/2086189414292865249")!),
                    confidence: 0.92,
                    rationale: "Explicit Codex quota reset schedule.",
                    text: "I'll do another reset tomorrow."),
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
            calendar: localDayCalendar)
    }
}

private extension RateLimitResetTodayEvent {
    var resetOccurrenceAt: Date? {
        switch kind {
        case .resetCompleted:
            effectiveAt ?? announcedAt
        case .resetScheduled:
            nil
        case .bankedReset, .limitIncrease, .uncertain:
            nil
        }
    }
}
