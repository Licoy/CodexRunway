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

public enum RateLimitResetType: String, Codable, Sendable, Equatable {
    case global
    case banked
    case globalAndBanked = "global_and_banked"

    public func includes(_ resetType: RateLimitResetType) -> Bool {
        self == resetType || self == .globalAndBanked
    }

    static func merging(_ resetTypes: [RateLimitResetType]) -> RateLimitResetType? {
        var hasGlobal = false
        var hasBanked = false
        for resetType in resetTypes {
            hasGlobal = hasGlobal || resetType.includes(.global)
            hasBanked = hasBanked || resetType.includes(.banked)
        }
        if hasGlobal, hasBanked { return .globalAndBanked }
        if hasBanked { return .banked }
        return hasGlobal ? .global : nil
    }
}

public enum RateLimitResetSchedulePrecision: String, Decodable, Sendable, Equatable {
    case date
    case datetime
}

public enum RateLimitResetScheduleBasis: String, Decodable, Sendable, Equatable {
    case explicit
    case contextualInference = "contextual_inference"
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
    public var resetType: RateLimitResetType
    public var announcedAt: Date
    public var effectiveAt: Date? = nil
    public var schedulePrecision: RateLimitResetSchedulePrecision? = nil
    public var scheduleBasis: RateLimitResetScheduleBasis? = nil
    public var scope: RateLimitResetTodayScope
    public var source: RateLimitResetTodaySource
    public var confidence: Double
    public var rationale: String
    /// Original subject post text from the feed. Validated on decode; UI uses app-owned copy.
    public var text: String

    public init(
        kind: RateLimitResetTodayEventKind,
        resetType: RateLimitResetType = .global,
        announcedAt: Date,
        effectiveAt: Date? = nil,
        schedulePrecision: RateLimitResetSchedulePrecision? = nil,
        scheduleBasis: RateLimitResetScheduleBasis? = nil,
        scope: RateLimitResetTodayScope,
        source: RateLimitResetTodaySource,
        confidence: Double,
        rationale: String,
        text: String)
    {
        self.kind = kind
        self.resetType = resetType
        self.announcedAt = announcedAt
        self.effectiveAt = effectiveAt
        self.schedulePrecision = schedulePrecision
        self.scheduleBasis = scheduleBasis
        self.scope = scope
        self.source = source
        self.confidence = confidence
        self.rationale = rationale
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case resetType
        case announcedAt
        case effectiveAt
        case schedulePrecision
        case scheduleBasis
        case scope
        case source
        case confidence
        case rationale
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(RateLimitResetTodayEventKind.self, forKey: .kind)
        // schemaVersion 1 feeds published before reset types are global. An
        // explicit null is invalid and must not be treated as an omitted field.
        resetType = container.contains(.resetType)
            ? try container.decode(RateLimitResetType.self, forKey: .resetType)
            : .global
        announcedAt = try container.decode(Date.self, forKey: .announcedAt)
        effectiveAt = try container.decodeIfPresent(Date.self, forKey: .effectiveAt)
        schedulePrecision = try container.decodeIfPresent(
            RateLimitResetSchedulePrecision.self,
            forKey: .schedulePrecision)
        scheduleBasis = try container.decodeIfPresent(
            RateLimitResetScheduleBasis.self,
            forKey: .scheduleBasis)
        scope = try container.decode(RateLimitResetTodayScope.self, forKey: .scope)
        source = try container.decode(RateLimitResetTodaySource.self, forKey: .source)
        confidence = try container.decode(Double.self, forKey: .confidence)
        rationale = try container.decode(String.self, forKey: .rationale)
        text = try container.decode(String.self, forKey: .text)
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

    /// Display ranges end at 23:59; lifecycle validity ends at the next midnight.
    public var pendingUntil: Date {
        isRange ? endAt.addingTimeInterval(60) : endAt
    }
}

public struct RateLimitResetPublishedWindow: Decodable, Sendable, Equatable {
    public var startAt: Date
    public var endAt: Date
    public var precision: RateLimitResetSchedulePrecision

    public init(startAt: Date, endAt: Date, precision: RateLimitResetSchedulePrecision) {
        self.startAt = startAt
        self.endAt = endAt
        self.precision = precision
    }
}

public struct RateLimitResetFulfilledSchedule: Decodable, Sendable, Equatable {
    public var schedule: RateLimitResetTodayEvent
    public var window: RateLimitResetPublishedWindow
    public var completionPostID: String
    public var completedAt: Date
    public var visibleUntil: Date
    public var fulfillmentOrigin: String?
    public var clusterID: String?

    private enum CodingKeys: String, CodingKey {
        case schedule
        case window
        case completionPostID = "completionPostId"
        case completedAt
        case visibleUntil
        case fulfillmentOrigin
        case clusterID = "clusterId"
    }

    public init(
        schedule: RateLimitResetTodayEvent,
        window: RateLimitResetPublishedWindow,
        completionPostID: String,
        completedAt: Date,
        visibleUntil: Date,
        fulfillmentOrigin: String? = nil,
        clusterID: String? = nil)
    {
        self.schedule = schedule
        self.window = window
        self.completionPostID = completionPostID
        self.completedAt = completedAt
        self.visibleUntil = visibleUntil
        self.fulfillmentOrigin = fulfillmentOrigin
        self.clusterID = clusterID
    }
}

public struct RateLimitResetManualCompletion: Decodable, Sendable, Equatable {
    public var id: String
    public var completedAt: Date
    public var visibleUntil: Date
    public var representativePostID: String
    public var schedulePostIDs: [String]
    public var schedules: [RateLimitResetTodayEvent]
    public var fulfillmentOrigin: String

    private enum CodingKeys: String, CodingKey {
        case id
        case completedAt
        case visibleUntil
        case representativePostID = "representativePostId"
        case schedulePostIDs = "schedulePostIds"
        case schedules
        case fulfillmentOrigin
    }

    public init(
        id: String,
        completedAt: Date,
        visibleUntil: Date,
        representativePostID: String,
        schedulePostIDs: [String],
        schedules: [RateLimitResetTodayEvent],
        fulfillmentOrigin: String = "manual")
    {
        self.id = id
        self.completedAt = completedAt
        self.visibleUntil = visibleUntil
        self.representativePostID = representativePostID
        self.schedulePostIDs = schedulePostIDs
        self.schedules = schedules
        self.fulfillmentOrigin = fulfillmentOrigin
    }

    public var representativeEvent: RateLimitResetTodayEvent? {
        schedules.first { $0.source.postID == representativePostID } ?? schedules.first
    }

    public var resetType: RateLimitResetType {
        RateLimitResetType.merging(schedules.map(\.resetType)) ?? .global
    }
}

public struct RateLimitResetTimeline: Sendable, Equatable {
    public var nextSchedule: RateLimitResetTodayEvent?
    public var recentNonCompletedPostId: String?
    public var fulfilledSchedules: [RateLimitResetFulfilledSchedule]
    public var manualCompletions: [RateLimitResetManualCompletion]
    public var suppressedPostIds: [String]

    public init(
        nextSchedule: RateLimitResetTodayEvent? = nil,
        recentNonCompletedPostId: String? = nil,
        fulfilledSchedules: [RateLimitResetFulfilledSchedule] = [],
        manualCompletions: [RateLimitResetManualCompletion] = [],
        suppressedPostIds: [String] = [])
    {
        self.nextSchedule = nextSchedule
        self.recentNonCompletedPostId = recentNonCompletedPostId
        self.fulfilledSchedules = fulfilledSchedules
        self.manualCompletions = manualCompletions
        self.suppressedPostIds = suppressedPostIds
    }
}

extension RateLimitResetTimeline: Decodable {
    private enum CodingKeys: String, CodingKey {
        case nextSchedule
        case recentNonCompletedPostId
        case fulfilledSchedules
        case manualCompletions
        case suppressedPostIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextSchedule = try container.decodeIfPresent(RateLimitResetTodayEvent.self, forKey: .nextSchedule)
        recentNonCompletedPostId = try container.decodeIfPresent(String.self, forKey: .recentNonCompletedPostId)
        fulfilledSchedules = try container.decodeIfPresent(
            [RateLimitResetFulfilledSchedule].self,
            forKey: .fulfilledSchedules) ?? []
        manualCompletions = try container.decodeIfPresent(
            [RateLimitResetManualCompletion].self,
            forKey: .manualCompletions) ?? []
        suppressedPostIds = try container.decodeIfPresent([String].self, forKey: .suppressedPostIds) ?? []
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
    public var resetTimeline: RateLimitResetTimeline?
    public private(set) var state: RateLimitResetTodayState
    public var fetchedAt: Date

    private var stateOverride: RateLimitResetTodayState?

    /// Official schemaVersion 1 feeds may omit `resetTimeline`; when present it is authoritative.
    public var hasResetTimeline: Bool { resetTimeline != nil }

    /// Compatibility initializer used by app-level service fixtures.
    public init(state: RateLimitResetTodayState, fetchedAt: Date = Date()) {
        self.schemaVersion = 1
        self.generatedAt = fetchedAt
        self.lastSuccessfulCheckAt = state == .unknown ? nil : fetchedAt
        self.monitor = RateLimitResetTodayMonitor(
            status: state == .unknown ? .degraded : .ok,
            errorCode: state == .unknown ? "mock_unavailable" : nil)
        self.events = []
        self.resetTimeline = nil
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
        self.resetTimeline = response.resetTimeline
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
        if hasCompletedResetEventToday(now: now, calendar: calendar) {
            return true
        }
        return visibleManualCompletion(onLocalDayOf: now, calendar: calendar) != nil
    }

    /// True when the hero/primary explanation should be a still-pending same-day schedule.
    ///
    /// Timeline-aware feeds make a confirmed completion (including a manual
    /// confirmation) the primary record. Legacy v1 feeds keep schedule-first.
    public func prefersSameDayScheduleExplanation(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> Bool
    {
        if hasResetTimeline, hasAlreadyEffectiveResetToday(now: now, calendar: calendar) {
            return false
        }
        return nextScheduledReset(onLocalDayOf: now, calendar: calendar) != nil
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
            if prefersSameDayScheduleExplanation(now: now, calendar: calendar),
               let nextSameDay = nextScheduledReset(onLocalDayOf: now, calendar: calendar)
            {
                return nextSameDay.event
            }
            if let completed = completedResetEventsToday(now: now, calendar: calendar)
                .max(by: { $0.announcedAt < $1.announcedAt })
            {
                return completed
            }
            if let manual = visibleManualCompletion(onLocalDayOf: now, calendar: calendar) {
                return manual.representativeEvent ?? latestEvent
            }
            return latestEvent
        case .no:
            // Same-day non-reset commentary explains today's "no".
            // A still-pending future schedule is also useful.
            // Do not fall back to latestEvent: past-day reset_completed
            // announcements are history, not evidence for today.
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
            return nextScheduledReset(now: now)?.event
        case .unknown:
            return latestEvent
        }
    }

    public func evidenceURL(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> URL?
    {
        primaryEvidenceEvent(now: now, calendar: calendar)?.source.url
    }

    /// Maps the event kind to app-owned copy; feed text is never shown directly.
    public func evidenceLine(
        l10n: L10n,
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> String?
    {
        if resolvedState(now: now, calendar: calendar) == .yes,
           !prefersSameDayScheduleExplanation(now: now, calendar: calendar),
           !hasCompletedResetEventToday(now: now, calendar: calendar),
           visibleManualCompletion(onLocalDayOf: now, calendar: calendar) != nil
        {
            return l10n.text(.rateLimitResetTodayEvidenceManualCompletion)
        }
        guard let event = primaryEvidenceEvent(now: now, calendar: calendar) else { return nil }
        let key: L10nKey = switch event.kind {
        case .resetCompleted:
            switch event.resetType {
            case .global:
                .rateLimitResetTodayEvidenceResetCompleted
            case .banked:
                .rateLimitResetTodayEvidenceBankedCompleted
            case .globalAndBanked:
                .rateLimitResetTodayEvidenceGlobalAndBankedCompleted
            }
        case .resetScheduled:
            if event.scheduleBasis == .contextualInference {
                switch event.resetType {
                case .global:
                    .rateLimitResetTodayEvidenceResetPreview
                case .banked:
                    .rateLimitResetTodayEvidenceBankedPreview
                case .globalAndBanked:
                    .rateLimitResetTodayEvidenceGlobalAndBankedPreview
                }
            } else {
                switch event.resetType {
                case .global:
                    .rateLimitResetTodayEvidenceResetScheduled
                case .banked:
                    .rateLimitResetTodayEvidenceBankedScheduled
                case .globalAndBanked:
                    .rateLimitResetTodayEvidenceGlobalAndBankedScheduled
                }
            }
        case .bankedReset:
            .rateLimitResetTodayEvidenceBankedReset
        case .limitIncrease:
            .rateLimitResetTodayEvidenceLimitIncrease
        case .uncertain:
            .rateLimitResetTodayEvidenceUncertain
        }
        return l10n.text(key)
    }

    public func displayResetType(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> RateLimitResetType?
    {
        guard resolvedState(now: now, calendar: calendar) != .unknown else { return nil }
        let completedTypes = completedResetEventsToday(now: now, calendar: calendar).map(\.resetType)
            + visibleManualCompletions(now: now)
            .filter { $0.completedAt <= now && calendar.isDate($0.completedAt, inSameDayAs: now) }
            .map(\.resetType)
        if let completedType = RateLimitResetType.merging(completedTypes) {
            return completedType
        }
        return nextScheduledReset(onLocalDayOf: now, calendar: calendar)?.event.resetType
    }

    public func latestReset(now: Date = Date()) -> (at: Date, resetType: RateLimitResetType)? {
        let fromEvents = events.compactMap { event -> (Date, RateLimitResetType)? in
            guard let occurredAt = event.resetOccurrenceAt, occurredAt <= now else { return nil }
            return (occurredAt, event.resetType)
        }
        let fromManual = (resetTimeline?.manualCompletions ?? [])
            .filter { $0.completedAt <= now }
            .map { ($0.completedAt, $0.resetType) }
        let occurrences = fromEvents + fromManual
        guard let latestAt = occurrences.map({ $0.0 }).max(),
              let resetType = RateLimitResetType.merging(
                  occurrences.filter { $0.0 == latestAt }.map { $0.1 })
        else {
            return nil
        }
        return (latestAt, resetType)
    }

    public func latestResetAt(now: Date = Date()) -> Date? {
        latestReset(now: now)?.at
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
        // Explicit producer precision is authoritative. Only legacy feeds that omit
        // schedulePrecision retain the Tibo-midnight-as-date compatibility rule.
        let isRange: Bool
        switch event.schedulePrecision {
        case .date:
            isRange = true
        case .datetime:
            isRange = false
        case nil:
            let components = sourceCalendar.dateComponents([.hour, .minute, .second], from: startAt)
            isRange = components.hour == 0 && components.minute == 0 && components.second == 0
        }
        guard isRange else {
            return RateLimitResetScheduleWindow(startAt: startAt, endAt: startAt, isRange: false)
        }
        let endAt = sourceCalendar.date(byAdding: .day, value: 1, to: startAt)!
            .addingTimeInterval(-60)
        return RateLimitResetScheduleWindow(startAt: startAt, endAt: endAt, isRange: true)
    }

    public func visibleManualCompletions(now: Date = Date()) -> [RateLimitResetManualCompletion] {
        guard let timeline = resetTimeline else { return [] }
        return timeline.manualCompletions
            .filter { now <= $0.visibleUntil }
            .sorted {
                if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                return $0.representativePostID > $1.representativePostID
            }
    }

    private func nextScheduledReset(
        after now: Date,
        matchingLocalDayOf day: Date?,
        calendar: Calendar?)
        -> (effectiveAt: Date, effectiveUntil: Date, isRange: Bool, event: RateLimitResetTodayEvent)?
    {
        if hasResetTimeline {
            return nextTimelineSchedule(after: now, matchingLocalDayOf: day, calendar: calendar)
        }
        var best: (
            effectiveAt: Date,
            effectiveUntil: Date,
            isRange: Bool,
            event: RateLimitResetTodayEvent)?
        for event in events {
            guard let candidate = pendingSchedule(event, after: now, matchingLocalDayOf: day, calendar: calendar)
            else { continue }
            if best == nil || candidate.effectiveAt < best!.effectiveAt {
                best = candidate
            }
        }
        return best
    }

    private func nextTimelineSchedule(
        after now: Date,
        matchingLocalDayOf day: Date?,
        calendar: Calendar?)
        -> (effectiveAt: Date, effectiveUntil: Date, isRange: Bool, event: RateLimitResetTodayEvent)?
    {
        guard let timeline = resetTimeline else { return nil }
        var best = timeline.nextSchedule.flatMap {
            pendingSchedule($0, after: now, matchingLocalDayOf: day, calendar: calendar)
        }
        let suppressedPostIDs = Set(timeline.suppressedPostIds)
        for event in events where event.kind == .resetScheduled && event.resetType == .banked {
            guard !suppressedPostIDs.contains(event.source.postID),
                  let candidate = pendingSchedule(
                      event,
                      after: now,
                      matchingLocalDayOf: day,
                      calendar: calendar)
            else {
                continue
            }
            if best == nil || candidate.effectiveAt < best!.effectiveAt {
                best = candidate
            }
        }
        return best
    }

    private func pendingSchedule(
        _ event: RateLimitResetTodayEvent,
        after now: Date,
        matchingLocalDayOf day: Date?,
        calendar: Calendar?)
        -> (effectiveAt: Date, effectiveUntil: Date, isRange: Bool, event: RateLimitResetTodayEvent)?
    {
        guard let window = scheduledResetWindow(for: event), window.pendingUntil > now else { return nil }
        if let day, let calendar, !intersectsLocalDay(window, day: day, calendar: calendar) {
            return nil
        }
        return (window.startAt, window.endAt, window.isRange, event)
    }

    private func hasCompletedResetEventToday(
        now: Date,
        calendar: Calendar) -> Bool
    {
        !completedResetEventsToday(now: now, calendar: calendar).isEmpty
    }

    private func completedResetEventsToday(
        now: Date,
        calendar: Calendar) -> [RateLimitResetTodayEvent]
    {
        events.filter { event in
            guard event.kind == .resetCompleted else { return false }
            guard let occurredAt = event.resetOccurrenceAt, occurredAt <= now else { return false }
            return calendar.isDate(occurredAt, inSameDayAs: now)
        }
    }

    private func visibleManualCompletion(
        onLocalDayOf now: Date,
        calendar: Calendar) -> RateLimitResetManualCompletion?
    {
        visibleManualCompletions(now: now).first { item in
            item.completedAt <= now && calendar.isDate(item.completedAt, inSameDayAs: now)
        }
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
