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
    public static func rateLimitResetTodayAlerts(
        previous: RateLimitResetTodaySnapshot?,
        current: RateLimitResetTodaySnapshot,
        now: Date = Date(),
        calendar: Calendar = .current) -> [RunwayAlert]
    {
        var alerts: [RunwayAlert] = []

        let currentYes = current.resolvedState(now: now, calendar: calendar) == .yes
        // Skip the very first successful load so app launch does not spam when a reset already exists.
        // Compare both snapshots against the same `now` so a new local-day reset is still detected.
        if let previous {
            let previousYes = previous.resolvedState(now: now, calendar: calendar) == .yes
            if currentYes, !previousYes {
                let postID = current.primaryEvidenceEvent(now: now, calendar: calendar)?.source.postID
                    ?? current.latestEvent?.source.postID
                    ?? "unknown"
                let day = calendar.startOfDay(for: now).timeIntervalSince1970
                alerts.append(RunwayAlert(
                    id: "rate-limit-reset:detected:\(postID):\(Int(day))",
                    kind: .rateLimitResetDetected,
                    name: postID,
                    threshold: nil,
                    date: current.latestResetAt(now: now)))
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
                    date: next.effectiveAt))
            }
        }

        return alerts
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
