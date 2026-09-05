import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Codex quota")
struct QuotaTests {
    @Test("cycle windows prefer the longest complete rate limit window")
    func cycleWindowsPreferLongestCompleteWindow() throws {
        let now = Date(timeIntervalSince1970: 1_782_710_000)
        let weeklyReset = now.addingTimeInterval(3 * 24 * 3_600)
        let fiveHourReset = now.addingTimeInterval(2 * 3_600)
        let snapshot = QuotaSnapshot(
            plan: "pro",
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: fiveHourReset),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10_080, resetsAt: weeklyReset),
            additionalWindows: [],
            creditsBalance: nil,
            updatedAt: now)

        let windows = try #require(snapshot.cycleWindows(now: now))
        #expect(windows.full.end == weeklyReset)
        #expect(windows.full.duration == TimeInterval(10_080 * 60))
        #expect(windows.elapsed.end == now)
    }

    @Test("cycle windows fall back to primary when secondary is incomplete")
    func cycleWindowsFallBackToPrimaryWhenSecondaryIncomplete() {
        let now = Date(timeIntervalSince1970: 1_782_710_000)
        let weeklyReset = now.addingTimeInterval(2 * 24 * 3_600)
        let snapshot = QuotaSnapshot(
            plan: "pro",
            primary: RateWindow(usedPercent: 72, windowMinutes: 10_080, resetsAt: weeklyReset),
            secondary: RateWindow(usedPercent: 5, windowMinutes: nil, resetsAt: nil),
            additionalWindows: [],
            creditsBalance: nil,
            updatedAt: now)

        let windows = snapshot.cycleWindows(now: now)
        #expect(windows?.full.end == weeklyReset)
        #expect(windows?.full.start == weeklyReset.addingTimeInterval(-10_080 * 60))
        #expect(windows?.elapsed.end == now)
    }

    @Test("decodes quota windows and additional limits")
    func decodesQuotaWindows() throws {
        let data = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {"used_percent": 72, "reset_at": 1782711351, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 40, "reset_at": 1783298151, "limit_window_seconds": 604800}
          },
          "credits": {"has_credits": true, "unlimited": false, "balance": "12.5"},
          "additional_rate_limits": [
            {
              "limit_name": "Codex Spark",
              "metered_feature": "spark",
              "rate_limit": {
                "primary_window": {"used_percent": 10, "reset_at": 1782711351, "limit_window_seconds": 18000}
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let snapshot = try QuotaSnapshot.decode(from: data, now: Date(timeIntervalSince1970: 1_782_710_000))

        #expect(snapshot.plan == "pro")
        #expect(snapshot.primary.usedPercent == 72)
        #expect(snapshot.primary.windowMinutes == 300)
        #expect(snapshot.secondary?.windowMinutes == 10_080)
        #expect(snapshot.creditsBalance == 12.5)
        #expect(snapshot.additionalWindows.first?.name == "Codex Spark")
        #expect(snapshot.menuBarText == "22 minutes")
        #expect(snapshot.menuBarText(now: Date(timeIntervalSince1970: 1_782_711_151)) == "3 minutes")
    }

    @Test("decodes reset credits")
    func decodesResetCredits() throws {
        let data = """
        {
          "available_count": 1,
          "credits": [
            {"id": "c1", "status": "available", "created_at": "2026-06-01T00:00:00Z", "expires_at": "2026-07-01T00:00:00Z"},
            {"id": "c2", "status": "used", "created_at": 1780272000, "expires_at": 1782864000}
          ]
        }
        """.data(using: .utf8)!

        let snapshot = try ResetCreditsSnapshot.decode(
            from: data,
            now: Date(timeIntervalSince1970: 1_782_000_000))

        #expect(snapshot.availableCount == 1)
        #expect(snapshot.credits.count == 2)
        #expect(snapshot.credits[0].status == "available")
        #expect(snapshot.credits[0].remainingSeconds > 0)
    }

    @Test("quota meter health follows remaining quota thresholds")
    func quotaMeterHealthThresholds() {
        #expect(QuotaMeter.health(forUsedPercent: 49) == .green)
        #expect(QuotaMeter.health(forUsedPercent: 50) == .green)
        #expect(QuotaMeter.health(forUsedPercent: 51) == .yellow)
        #expect(QuotaMeter.health(forUsedPercent: 80) == .yellow)
        #expect(QuotaMeter.health(forUsedPercent: 81) == .red)
    }

    @Test("quota meters expose remaining percentage and reset text")
    func quotaMetersExposeProgressValues() {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = RateWindow(
            usedPercent: 29,
            windowMinutes: 300,
            resetsAt: Date(timeIntervalSince1970: 1_000 + 3 * 3_600 + 7 * 60))

        let meter = QuotaMeter(title: "5-hour", window: window, now: now)

        #expect(meter.remainingPercent == 71)
        #expect(meter.usedPercent == 29)
        #expect(meter.health == .green)
        #expect(meter.resetsAt == window.resetsAt)
        #expect(meter.resetText == "3 hours 7 minutes")
    }

    @Test("quota burn projection predicts exhaustion before reset")
    func quotaBurnProjectionPredictsExhaustion() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(2 * 3_600)
        let window = RateWindow(
            usedPercent: 80,
            windowMinutes: 300,
            resetsAt: start.addingTimeInterval(5 * 3_600))

        let projection = try #require(QuotaBurnProjection.make(window: window, now: now))

        #expect(projection.exhaustsAt == now.addingTimeInterval(30 * 60))
        #expect(projection.projectedUsedPercentAtReset == 100)
    }

    @Test("quota burn projection estimates reset usage when not exhausted")
    func quotaBurnProjectionEstimatesResetUsage() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(2 * 3_600)
        let window = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: start.addingTimeInterval(5 * 3_600))

        let projection = try #require(QuotaBurnProjection.make(window: window, now: now))

        #expect(projection.exhaustsAt == nil)
        #expect(projection.projectedUsedPercentAtReset == 50)
    }

    @Test("quota reset is due one second after reset time once")
    func quotaResetDueAfterOneSecond() {
        let primaryReset = Date(timeIntervalSince1970: 1_000)
        let weeklyReset = Date(timeIntervalSince1970: 2_000)
        let snapshot = QuotaSnapshot(
            plan: nil,
            primary: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: primaryReset),
            secondary: RateWindow(usedPercent: 10, windowMinutes: 10_080, resetsAt: weeklyReset),
            additionalWindows: [],
            creditsBalance: nil,
            updatedAt: Date(timeIntervalSince1970: 900))

        #expect(snapshot.nextDueReset(after: nil, now: Date(timeIntervalSince1970: 1_000.9)) == nil)
        #expect(snapshot.nextDueReset(after: nil, now: Date(timeIntervalSince1970: 1_001)) == primaryReset)
        #expect(snapshot.nextDueReset(after: primaryReset, now: Date(timeIntervalSince1970: 1_001)) == nil)
        #expect(snapshot.nextDueReset(after: primaryReset, now: Date(timeIntervalSince1970: 2_001)) == weeklyReset)
    }

    @Test("reset credit summary filters available credits and finds expiry bounds")
    func resetCreditSummary() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = ResetCreditsSnapshot(
            availableCount: 2,
            credits: [
                ResetCredit(id: "a", status: "available", createdAt: nil, expiresAt: Date(timeIntervalSince1970: 1_100), remainingSeconds: 100),
                ResetCredit(id: "b", status: "used", createdAt: nil, expiresAt: Date(timeIntervalSince1970: 1_050), remainingSeconds: 50),
                ResetCredit(id: "c", status: "available", createdAt: nil, expiresAt: Date(timeIntervalSince1970: 1_300), remainingSeconds: 300),
            ],
            updatedAt: now)

        let summary = ResetCreditSummary(snapshot: snapshot)

        #expect(summary.availableCount == 2)
        #expect(summary.totalCount == 3)
        #expect(summary.nextExpiryDate == Date(timeIntervalSince1970: 1_100))
        #expect(summary.nextExpiryRemaining == 100)
        #expect(summary.latestExpiryDate == Date(timeIntervalSince1970: 1_300))
        #expect(summary.latestExpiryRemaining == 300)
    }

    @Test("reset credit summary classifies expiration risk")
    func resetCreditRiskCounts() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = ResetCreditsSnapshot(
            availableCount: 3,
            credits: [
                ResetCredit(id: "stable", status: "available", createdAt: nil, expiresAt: Date(timeIntervalSince1970: 1_000 + 8 * 86_400), remainingSeconds: 8 * 86_400),
                ResetCredit(id: "expiring", status: "available", createdAt: nil, expiresAt: Date(timeIntervalSince1970: 1_000 + 2 * 86_400), remainingSeconds: 2 * 86_400),
                ResetCredit(id: "none", status: "available", createdAt: nil, expiresAt: nil, remainingSeconds: 0),
                ResetCredit(id: "used", status: "used", createdAt: nil, expiresAt: Date(timeIntervalSince1970: 1_100), remainingSeconds: 100),
            ],
            updatedAt: now)

        let summary = ResetCreditSummary(snapshot: snapshot)

        #expect(summary.stableAvailableCount == 2)
        #expect(summary.expiringCount == 1)
        #expect(summary.unavailableCount == 1)
        #expect(ResetCreditRisk.classify(snapshot.credits[0]) == .available)
        #expect(ResetCreditRisk.classify(snapshot.credits[1]) == .expiring)
        #expect(ResetCreditRisk.classify(snapshot.credits[3]) == .unavailable)
    }

    @Test("reset credits sort by expiry with no expiry last")
    func resetCreditsSortByExpiry() {
        let credits = [
            ResetCredit(id: "none", status: "available", createdAt: nil, expiresAt: nil, remainingSeconds: 0),
            ResetCredit(id: "later", status: "available", createdAt: nil, expiresAt: Date(timeIntervalSince1970: 3_000), remainingSeconds: 2_000),
            ResetCredit(id: "soon", status: "available", createdAt: nil, expiresAt: Date(timeIntervalSince1970: 2_000), remainingSeconds: 1_000),
        ]

        #expect(ResetCreditSummary.sortedByExpiry(credits).map(\.id) == ["soon", "later", "none"])
    }

    @Test("alert store only returns unseen quota and reset credit alerts")
    func alertStoreDeduplicatesAlerts() throws {
        let root = try TemporaryDirectory()
        let store = RunwayAlertStore(stateURL: root.url.appending(path: "alerts.json"))
        let now = Date(timeIntervalSince1970: 1_000)
        let quota = QuotaSnapshot(
            plan: nil,
            primary: RateWindow(usedPercent: 96, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 2_000)),
            secondary: nil,
            additionalWindows: [],
            creditsBalance: nil,
            updatedAt: now)
        let credits = ResetCreditsSnapshot(
            availableCount: 1,
            credits: [
                ResetCredit(
                    id: "credit-1",
                    status: "available",
                    createdAt: nil,
                    expiresAt: now.addingTimeInterval(2 * 86_400),
                    remainingSeconds: 2 * 86_400),
            ],
            updatedAt: now)
        let alerts = RunwayAlertDecider.quotaAlerts(quota) + RunwayAlertDecider.resetCreditAlerts(credits)

        #expect(try store.unseen(alerts).map(\.id) == alerts.map(\.id))
        #expect(try store.unseen(alerts).isEmpty)
    }

    @Test("user notifications require app bundle runtime")
    func userNotificationsRequireAppBundleRuntime() {
        #expect(UserNotificationEnvironment(bundlePathExtension: "app").canUseUserNotifications)
        #expect(UserNotificationEnvironment(bundlePathExtension: "").canUseUserNotifications == false)
        #expect(UserNotificationEnvironment(bundlePathExtension: "debug").canUseUserNotifications == false)
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        self.url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
