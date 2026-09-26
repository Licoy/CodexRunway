import Foundation

extension RateLimitResetTodaySnapshot {
    var mergedScheduleCandidates: [RateLimitResetTodayEvent] {
        var merged = [RateLimitResetTodayEvent]()
        var indices = [String: Int]()
        func insert(_ event: RateLimitResetTodayEvent) {
            if let index = indices[event.source.postID] {
                merged[index] = event
            } else {
                indices[event.source.postID] = merged.count
                merged.append(event)
            }
        }
        for event in events where event.kind == .resetScheduled {
            insert(event)
        }
        if let nextSchedule = resetTimeline?.nextSchedule {
            insert(nextSchedule)
        }
        for event in graceSchedules {
            insert(event)
        }
        return merged
    }

    func hasCompletion(
        for schedule: RateLimitResetTodayEvent,
        window: RateLimitResetScheduleWindow,
        through now: Date) -> Bool
    {
        let suppressed = Set(resetTimeline?.suppressedPostIds ?? [])
        let lowerBound = completionLowerBound(for: schedule, window: window)
        if events.contains(where: {
            guard $0.kind == .resetCompleted,
                  !suppressed.contains($0.source.postID),
                  $0.announcedAt >= schedule.announcedAt,
                  $0.resetType.includes(schedule.resetType),
                  scopesAreCompatible(schedule.scope, $0.scope)
            else { return false }
            let at = $0.effectiveAt ?? $0.announcedAt
            return lowerBound <= at && at <= now
        }) {
            return true
        }
        return (resetTimeline?.manualCompletions ?? []).contains {
            let typeMatches = schedule.resetType == .globalAndBanked
                || $0.resetType.includes(schedule.resetType)
            return typeMatches
                && schedule.announcedAt <= $0.completedAt
                && lowerBound <= $0.completedAt
                && $0.completedAt <= now
        }
    }

    private func completionLowerBound(
        for schedule: RateLimitResetTodayEvent,
        window: RateLimitResetScheduleWindow) -> Date
    {
        if window.isRange { return window.startAt }
        guard let effectiveAt = schedule.effectiveAt else { return window.startAt }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return min(calendar.startOfDay(for: effectiveAt), effectiveAt.addingTimeInterval(-30 * 60))
    }

    private func scopesAreCompatible(
        _ left: RateLimitResetTodayScope,
        _ right: RateLimitResetTodayScope) -> Bool
    {
        axesAreCompatible(left.plans, right.plans, wildcards: ["all", "unknown"])
            && axesAreCompatible(left.windows, right.windows, wildcards: ["unknown"])
    }

    private func axesAreCompatible(
        _ left: [String],
        _ right: [String],
        wildcards: Set<String>) -> Bool
    {
        let leftValues = Set(left)
        let rightValues = Set(right)
        return leftValues.isEmpty
            || rightValues.isEmpty
            || !leftValues.isDisjoint(with: wildcards)
            || !rightValues.isDisjoint(with: wildcards)
            || !leftValues.isDisjoint(with: rightValues)
    }
}
