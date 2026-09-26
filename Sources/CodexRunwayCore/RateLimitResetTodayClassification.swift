import Foundation

public enum RateLimitResetTodayVerdictReason: String, Codable, Sendable, Equatable {
    case completed
    case upcoming
    case grace
    case expiredUnconfirmed
    case none
    case unavailable

    public var questionKey: L10nKey {
        switch self {
        case .upcoming: .rateLimitResetQuestionUpcoming
        case .grace: .rateLimitResetQuestionScheduledGrace
        case .unavailable: .rateLimitResetQuestionUnavailable
        case .completed, .expiredUnconfirmed, .none: .rateLimitResetQuestionCurrent
        }
    }

    public func questionText(l10n: L10n) -> String {
        l10n.text(questionKey)
    }
}

public struct RateLimitResetUpcomingSummary: Sendable, Equatable {
    public var window: RateLimitResetScheduleWindow
    public var event: RateLimitResetTodayEvent
    public var resetType: RateLimitResetType
    public var confidence: Double
    public var scheduleBasis: RateLimitResetScheduleBasis?

    public var effectiveAt: Date { window.startAt }
    public var effectiveUntil: Date { window.endAt }
    public var isRange: Bool { window.isRange }
}

extension RateLimitResetTodaySnapshot {
    /// Earliest open schedule with same-time reset types merged independently of its evidence event.
    public func nextScheduledResetSummary(now: Date = Date()) -> RateLimitResetUpcomingSummary? {
        let candidates = [RateLimitResetType.global, .banked].compactMap { type in
            upcomingCandidate(for: type, now: now).map { (type, $0) }
        }
        guard let firstAt = candidates.map({ $0.1.window.startAt }).min() else { return nil }
        let matching = candidates.filter { $0.1.window.startAt == firstAt }
        guard let first = matching.first,
              let resetType = RateLimitResetType.merging(matching.map { $0.0 })
        else { return nil }
        let contextual = matching.allSatisfy {
            $0.1.event.scheduleBasis == .contextualInference
        }
        return RateLimitResetUpcomingSummary(
            window: first.1.window,
            event: first.1.event,
            resetType: resetType,
            confidence: matching.map { $0.1.event.confidence }.min() ?? first.1.event.confidence,
            scheduleBasis: contextual ? .contextualInference : first.1.event.scheduleBasis)
    }

    /// Times at which the same immutable snapshot can produce a different verdict.
    public func nextVerdictTransitionDates(
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> [Date]
    {
        let scheduledEvents = mergedScheduleCandidates
        let schedules = scheduledEvents.compactMap { event in
            scheduledResetWindow(for: event).map { (event, $0) }
        }
        var dates = schedules.map { $0.1.startAt }
        dates += schedules.map { $0.1.pendingUntil }
        dates += schedules.compactMap { event, window in
            event.graceDeadline(after: window.pendingUntil)
        }
        dates += events.compactMap { event in
            event.kind == .resetCompleted ? (event.effectiveAt ?? event.announcedAt) : nil
        }
        for manual in resetTimeline?.manualCompletions ?? [] {
            dates.append(manual.completedAt)
            dates.append(manual.visibleUntil.addingTimeInterval(1))
        }
        let staleTransition = freshnessAt?.addingTimeInterval(Self.staleAfter + 1)
        if let freshnessAt {
            dates.append(freshnessAt.addingTimeInterval(Self.staleAfter + 1))
        }
        var midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        var remainingMidnights = 64
        while let value = midnight,
              value <= (staleTransition ?? value),
              remainingMidnights > 0
        {
            dates.append(value)
            midnight = calendar.date(byAdding: .day, value: 1, to: value)
            remainingMidnights -= 1
        }
        return Array(Set(dates.filter { $0 > now })).sorted()
    }
}

struct RateLimitResetVerdictCandidate {
    var reason: RateLimitResetTodayVerdictReason
    var state: RateLimitResetTodayState
    var event: RateLimitResetTodayEvent?
    var window: RateLimitResetScheduleWindow?
    var confidence: Double?
    var completedAt: Date?
    var scheduleBasis: RateLimitResetScheduleBasis? = nil

    var timestamp: Date {
        switch reason {
        case .completed: completedAt ?? .distantPast
        case .upcoming: window?.startAt ?? .distantFuture
        case .grace, .expiredUnconfirmed: window?.pendingUntil ?? .distantPast
        case .none, .unavailable: .distantFuture
        }
    }
}

extension RateLimitResetTodaySnapshot {
    func combinedVerdictCandidate(now: Date, calendar: Calendar)
        -> (candidate: RateLimitResetVerdictCandidate, resetType: RateLimitResetType?)
    {
        guard monitor.status == .ok,
              let freshnessAt,
              now.timeIntervalSince(freshnessAt) <= Self.staleAfter
        else {
            return (RateLimitResetVerdictCandidate(
                reason: .unavailable,
                state: .unknown,
                event: nil,
                window: nil,
                confidence: nil,
                completedAt: nil), nil)
        }

        let byType = [
            (RateLimitResetType.global, verdictCandidate(for: .global, now: now, calendar: calendar)),
            (RateLimitResetType.banked, verdictCandidate(for: .banked, now: now, calendar: calendar)),
        ]
        let completed = byType.filter { $0.1.reason == .completed }
        if !completed.isEmpty {
            return merge(completed, reason: .completed, state: .yes)
        }

        var scheduled = byType.filter {
            [.upcoming, .grace, .expiredUnconfirmed].contains($0.1.reason)
        }
        guard !scheduled.isEmpty else {
            return (RateLimitResetVerdictCandidate(
                reason: .none,
                state: .no,
                event: nil,
                window: nil,
                confidence: nil,
                completedAt: nil), nil)
        }
        let live = scheduled.filter { $0.1.reason == .upcoming }
        let grace = scheduled.filter { $0.1.reason == .grace }
        scheduled = !live.isEmpty ? live : (!grace.isEmpty ? grace : scheduled)
        let affirmative = scheduled.filter { $0.1.state == .yes }
        var selected = affirmative.isEmpty ? scheduled : affirmative
        let newestFirst = live.isEmpty && !grace.isEmpty
        selected.sort {
            newestFirst ? $0.1.timestamp > $1.1.timestamp : $0.1.timestamp < $1.1.timestamp
        }
        let timestamp = selected[0].1.timestamp
        let matching = selected.filter { $0.1.timestamp == timestamp }
        return merge(matching, reason: selected[0].1.reason, state: matching.contains { $0.1.state == .yes } ? .yes : .no)
    }

    private func merge(
        _ candidates: [(RateLimitResetType, RateLimitResetVerdictCandidate)],
        reason: RateLimitResetTodayVerdictReason,
        state: RateLimitResetTodayState)
        -> (candidate: RateLimitResetVerdictCandidate, resetType: RateLimitResetType?)
    {
        let representative = candidates.max { $0.1.timestamp < $1.1.timestamp }!.1
        let confidence = candidates.compactMap { $0.1.confidence }.min()
        let type = RateLimitResetType.merging(candidates.map { $0.0 })
        let scheduleBasis: RateLimitResetScheduleBasis?
        if reason == .upcoming || reason == .grace {
            let contextual = candidates.allSatisfy {
                $0.1.event?.scheduleBasis == .contextualInference
            }
            scheduleBasis = contextual
                ? .contextualInference
                : candidates[0].1.event?.scheduleBasis
        } else {
            scheduleBasis = nil
        }
        return (RateLimitResetVerdictCandidate(
            reason: reason,
            state: state,
            event: representative.event,
            window: representative.window,
            confidence: confidence,
            completedAt: candidates.compactMap { $0.1.completedAt }.max(),
            scheduleBasis: scheduleBasis), type)
    }

    private func verdictCandidate(
        for type: RateLimitResetType,
        now: Date,
        calendar: Calendar) -> RateLimitResetVerdictCandidate
    {
        if let completed = completedCandidate(for: type, now: now, calendar: calendar) {
            return completed
        }
        if let upcoming = upcomingCandidate(for: type, now: now) {
            let state: RateLimitResetTodayState = isWindow(
                upcoming.window,
                onLocalDayOf: now,
                calendar: calendar) && upcoming.event.scheduleBasis != .contextualInference ? .yes : .no
            return RateLimitResetVerdictCandidate(
                reason: .upcoming,
                state: state,
                event: upcoming.event,
                window: upcoming.window,
                confidence: upcoming.event.confidence,
                completedAt: nil)
        }
        if let grace = graceCandidate(for: type, now: now) {
            return RateLimitResetVerdictCandidate(
                reason: .grace,
                state: .yes,
                event: grace.event,
                window: grace.window,
                confidence: grace.event.confidence,
                completedAt: nil)
        }
        if let expired = mergedScheduleCandidates.first(where: {
            $0.kind == .resetScheduled
                && $0.resetType.includes(type)
                && scheduledResetWindow(for: $0).map {
                    $0.pendingUntil <= now && calendar.isDate($0.pendingUntil, inSameDayAs: now)
                } == true
        }), let window = scheduledResetWindow(for: expired) {
            return RateLimitResetVerdictCandidate(
                reason: .expiredUnconfirmed,
                state: .no,
                event: expired,
                window: window,
                confidence: expired.confidence,
                completedAt: nil)
        }
        return RateLimitResetVerdictCandidate(
            reason: .none,
            state: .no,
            event: nil,
            window: nil,
            confidence: nil,
            completedAt: nil)
    }

    private func completedCandidate(
        for type: RateLimitResetType,
        now: Date,
        calendar: Calendar) -> RateLimitResetVerdictCandidate?
    {
        let eventCandidates = events.compactMap { event -> (RateLimitResetTodayEvent, Date)? in
            guard event.kind == .resetCompleted,
                  event.resetType.includes(type)
            else { return nil }
            let at = event.effectiveAt ?? event.announcedAt
            guard at <= now, calendar.isDate(at, inSameDayAs: now) else { return nil }
            return (event, at)
        }
        let manualCandidates = visibleManualCompletions(now: now).compactMap {
            $0.resetType.includes(type) && $0.completedAt <= now
                && calendar.isDate($0.completedAt, inSameDayAs: now) ? $0 : nil
        }
        if let first = eventCandidates.first {
            let evidence = eventCandidates.max {
                if $0.0.announcedAt != $1.0.announcedAt {
                    return $0.0.announcedAt < $1.0.announcedAt
                }
                return $0.0.source.postID < $1.0.source.postID
            }!.0
            let completedAt = (eventCandidates.map { $0.1 } + manualCandidates.map(\.completedAt)).max()
            return RateLimitResetVerdictCandidate(
                reason: .completed,
                state: .yes,
                event: evidence,
                window: nil,
                confidence: first.0.confidence,
                completedAt: completedAt)
        }
        guard let manual = manualCandidates.first else { return nil }
        let latestManual = manualCandidates.max { $0.completedAt < $1.completedAt } ?? manual
        return RateLimitResetVerdictCandidate(
            reason: .completed,
            state: .yes,
            event: latestManual.representativeEvent,
            window: nil,
            confidence: nil,
            completedAt: latestManual.completedAt)
    }

    private func upcomingCandidate(for type: RateLimitResetType, now: Date)
        -> (event: RateLimitResetTodayEvent, window: RateLimitResetScheduleWindow)?
    {
        if let timeline = resetTimeline, type == .global {
            guard let primary = timeline.nextSchedule else { return nil }
            if primary.resetType.includes(type) {
                guard let window = scheduledResetWindow(for: primary),
                      window.pendingUntil > now
                else { return nil }
                return (primary, window)
            }
        }
        let suppressed = Set(resetTimeline?.suppressedPostIds ?? [])
        return mergedScheduleCandidates.compactMap { event -> (RateLimitResetTodayEvent, RateLimitResetScheduleWindow)? in
            guard event.kind == .resetScheduled,
                  event.resetType.includes(type),
                  !suppressed.contains(event.source.postID),
                  let window = scheduledResetWindow(for: event),
                  window.pendingUntil > now
            else { return nil }
            return (event, window)
        }.min { $0.1.startAt < $1.1.startAt }
    }

    private func graceCandidate(for type: RateLimitResetType, now: Date)
        -> (event: RateLimitResetTodayEvent, window: RateLimitResetScheduleWindow)?
    {
        let suppressed = Set(resetTimeline?.suppressedPostIds ?? [])
        let fulfilled = fulfilledSchedulePostIDs
        return mergedScheduleCandidates.compactMap { event -> (RateLimitResetTodayEvent, RateLimitResetScheduleWindow)? in
            guard event.kind == .resetScheduled,
                  event.resetType.includes(type),
                  !suppressed.contains(event.source.postID),
                  !fulfilled.contains(event.source.postID),
                  let window = scheduledResetWindow(for: event),
                  window.pendingUntil <= now,
                  let deadline = event.graceDeadline(after: window.pendingUntil),
                  window.pendingUntil < deadline,
                  now < deadline,
                  !hasCompletion(for: event, window: window, through: now)
            else { return nil }
            return (event, window)
        }.max {
            if $0.1.pendingUntil != $1.1.pendingUntil { return $0.1.pendingUntil < $1.1.pendingUntil }
            if $0.0.announcedAt != $1.0.announcedAt { return $0.0.announcedAt < $1.0.announcedAt }
            return $0.0.source.postID < $1.0.source.postID
        }
    }

    private var fulfilledSchedulePostIDs: Set<String> {
        guard let timeline = resetTimeline else { return [] }
        var ids = Set(timeline.fulfilledSchedules.map { $0.schedule.source.postID })
        for manual in timeline.manualCompletions {
            ids.formUnion(manual.schedulePostIDs)
            ids.formUnion(manual.schedules.map { $0.source.postID })
        }
        return ids
    }

    private func isWindow(
        _ window: RateLimitResetScheduleWindow,
        onLocalDayOf day: Date,
        calendar: Calendar) -> Bool
    {
        if window.startAt <= day, day < window.pendingUntil { return true }
        if calendar.isDate(window.startAt, inSameDayAs: day) { return true }
        return window.isRange && calendar.isDate(window.endAt, inSameDayAs: day)
    }
}
