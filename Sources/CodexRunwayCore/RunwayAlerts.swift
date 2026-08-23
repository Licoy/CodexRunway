import Foundation

public enum RunwayAlertKind: String, Codable, Sendable, Equatable {
    case quota
    case resetCredit
    case rateLimitResetDetected
    case rateLimitResetUpcoming
}

public struct RunwayAlert: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: RunwayAlertKind
    public var name: String
    public var threshold: Int?
    public var date: Date?
    public var endDate: Date?
    public var resetType: RateLimitResetType?

    public init(
        id: String,
        kind: RunwayAlertKind,
        name: String,
        threshold: Int?,
        date: Date?,
        endDate: Date? = nil,
        resetType: RateLimitResetType? = nil)
    {
        self.id = id
        self.kind = kind
        self.name = name
        self.threshold = threshold
        self.date = date
        self.endDate = endDate
        self.resetType = resetType
    }
}

public enum RunwayAlertDecider {
    private static let quotaThresholds = [80, 95, 100]
    private static let upcomingThresholdMinutes = [60, 30]

    public static func quotaAlerts(_ snapshot: QuotaSnapshot) -> [RunwayAlert] {
        var rows = [("5-hour", snapshot.primary)]
        if let secondary = snapshot.secondary { rows.append(("Weekly", secondary)) }
        rows.append(contentsOf: snapshot.additionalWindows.map { ($0.name, $0.window) })
        return rows.compactMap { name, window in
            guard let threshold = quotaThresholds.last(where: { window.usedPercent >= $0 }) else { return nil }
            let resetID = window.resetsAt.map { Int($0.timeIntervalSince1970) } ?? 0
            return RunwayAlert(
                id: "quota:\(name):\(threshold):\(resetID)",
                kind: .quota,
                name: name,
                threshold: threshold,
                date: window.resetsAt)
        }
    }

    public static func resetCreditAlerts(_ snapshot: ResetCreditsSnapshot) -> [RunwayAlert] {
        snapshot.credits.compactMap { credit in
            guard ResetCreditRisk.classify(credit) == .expiring else { return nil }
            let expiryID = credit.expiresAt.map { Int($0.timeIntervalSince1970) } ?? 0
            let creditID = credit.id ?? "\(expiryID)"
            return RunwayAlert(
                id: "reset-credit:\(creditID):\(expiryID)",
                kind: .resetCredit,
                name: creditID,
                threshold: nil,
                date: credit.expiresAt)
        }
    }

    /// Alerts when a reset becomes newly detected, or when a scheduled reset is within 1h / 30m.
    ///
    /// "Today" uses the viewer's local Gregorian day (via `calendar`), not the UTC
    /// date prefix on feed timestamps — otherwise a late-UTC reset can notify the
    /// wrong local calendar day.
    public static func rateLimitResetTodayAlerts(
        previous: RateLimitResetTodaySnapshot?,
        current: RateLimitResetTodaySnapshot,
        now: Date = Date(),
        calendar: Calendar = RateLimitResetTodaySnapshot.localDayCalendar) -> [RunwayAlert]
    {
        var alerts: [RunwayAlert] = []

        // Skip the first successful load so app launch does not spam for existing resets.
        // Identity, rather than type, owns detection so a classification correction does not re-alert.
        if let previous {
            let previousIDs = Set(resetOccurrences(in: previous, now: now, calendar: calendar).map(\.id))
            let day = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
            for occurrence in resetOccurrences(in: current, now: now, calendar: calendar)
                where !previousIDs.contains(occurrence.id)
            {
                alerts.append(RunwayAlert(
                    id: "rate-limit-reset:detected:\(occurrence.id):\(day)",
                    kind: .rateLimitResetDetected,
                    name: occurrence.name,
                    threshold: nil,
                    date: occurrence.date,
                    resetType: occurrence.resetType))
            }
        }

        if let next = current.nextScheduledReset(now: now) {
            let remaining = next.effectiveAt.timeIntervalSince(now)
            guard remaining > 0 else { return alerts }
            // Prefer the tighter threshold so a late refresh only fires once.
            let minutes = Int(ceil(remaining / 60))
            let threshold: Int?
            if minutes <= 30 {
                threshold = 30
            } else if minutes <= 60 {
                threshold = 60
            } else {
                threshold = nil
            }
            if let threshold {
                let effectiveID = Int(next.effectiveAt.timeIntervalSince1970)
                let postID = next.event.source.postID
                alerts.append(RunwayAlert(
                    id: "rate-limit-reset:upcoming:\(postID):\(threshold):\(effectiveID)",
                    kind: .rateLimitResetUpcoming,
                    name: postID,
                    threshold: threshold,
                    date: next.effectiveAt,
                    endDate: next.isRange ? next.effectiveUntil : nil,
                    resetType: next.event.resetType))
            }
        }

        return alerts
    }

    private struct ResetOccurrence {
        var id: String
        var name: String
        var date: Date
        var resetType: RateLimitResetType
    }

    private static func resetOccurrences(
        in snapshot: RateLimitResetTodaySnapshot,
        now: Date,
        calendar: Calendar) -> [ResetOccurrence]
    {
        var occurrences = snapshot.events.compactMap { event -> ResetOccurrence? in
            guard event.kind == .resetCompleted else { return nil }
            let date = event.effectiveAt ?? event.announcedAt
            guard date <= now, calendar.isDate(date, inSameDayAs: now) else { return nil }
            return ResetOccurrence(
                id: event.source.postID,
                name: event.source.postID,
                date: date,
                resetType: event.resetType)
        }
        occurrences += snapshot.visibleManualCompletions(now: now).compactMap { completion in
            guard completion.completedAt <= now,
                  calendar.isDate(completion.completedAt, inSameDayAs: now)
            else { return nil }
            return ResetOccurrence(
                id: completion.id,
                name: completion.representativePostID,
                date: completion.completedAt,
                resetType: completion.resetType)
        }
        occurrences.sort { lhs, rhs in
            lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
        }
        var seen = Set<String>()
        return occurrences.filter { seen.insert($0.id).inserted }
    }
}

public struct RunwayAlertStore: Sendable {
    public var stateURL: URL

    public init(stateURL: URL = Self.defaultStateURL) {
        self.stateURL = stateURL
    }

    public func unseen(_ alerts: [RunwayAlert]) throws -> [RunwayAlert] {
        var ids = load()
        let unseen = alerts.filter { !ids.contains($0.id) }
        guard !unseen.isEmpty else { return [] }
        unseen.forEach { ids.insert($0.id) }
        try save(ids)
        return unseen
    }

    private func load() -> Set<String> {
        guard let data = try? Data(contentsOf: stateURL),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(values)
    }

    private func save(_ ids: Set<String>) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Array(ids).sorted().suffix(200))
        try data.write(to: stateURL, options: .atomic)
    }

    public static var defaultStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-runway", isDirectory: true)
            .appendingPathComponent("alerts.json")
    }
}

public struct UserNotificationEnvironment: Sendable, Equatable {
    public var bundlePathExtension: String

    public init(bundlePathExtension: String) {
        self.bundlePathExtension = bundlePathExtension
    }

    public var canUseUserNotifications: Bool {
        bundlePathExtension.lowercased() == "app"
    }
}
