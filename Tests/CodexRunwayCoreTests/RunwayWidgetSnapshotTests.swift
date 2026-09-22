import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Runway widget snapshot")
struct RunwayWidgetSnapshotTests {
    @Test("snapshot round trips and never encodes sensitive account fields")
    func codableRoundTrip() throws {
        let snapshot = fixture()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let text = String(decoding: data, as: UTF8.self)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(RunwayWidgetSnapshot.self, from: data) == snapshot)
        #expect(!text.contains("email"))
        #expect(!text.contains("accountId"))
        #expect(!text.contains("accessToken"))
        #expect(!text.contains("refreshToken"))
        #expect(!text.contains("rationale"))
        #expect(!text.contains("text"))
        #expect(text.contains("\"resetType\":\"global_and_banked\""))
        #expect(text.contains("\"nextScheduledResetType\":\"banked\""))
        #expect(text.contains("\"confidencePercent\":92"))
        #expect(text.contains("\"confidenceBand\":\"ok\""))
        #expect(text.contains("\"scheduleBasis\":\"explicit\""))
    }

    @Test("legacy snapshots decode without reset type fields")
    func legacySnapshotWithoutResetTypes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(fixture())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var resetToday = try #require(object["resetToday"] as? [String: Any])
        resetToday.removeValue(forKey: "resetType")
        resetToday.removeValue(forKey: "nextScheduledResetType")
        resetToday.removeValue(forKey: "confidencePercent")
        resetToday.removeValue(forKey: "confidenceBand")
        resetToday.removeValue(forKey: "timeline")
        object["resetToday"] = resetToday

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RunwayWidgetSnapshot.self, from: legacyData)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.resetToday?.resetType == nil)
        #expect(decoded.resetToday?.nextScheduledResetType == nil)
        #expect(decoded.resetToday?.confidencePercent == nil)
        #expect(decoded.resetToday?.confidenceBand == nil)
        #expect(decoded.resetToday?.timeline == nil)
        #expect(decoded.resetToday?.presentation(at: Date()) == nil)
    }

    @Test("reset timeline selects the last precomputed presentation at entry date")
    func resetTimelineSelection() throws {
        let reset = try #require(fixture().resetToday)
        let first = try #require(reset.timeline?.first)
        let second = try #require(reset.timeline?.last)

        #expect(reset.presentation(at: first.effectiveAt) == first)
        #expect(reset.presentation(at: second.effectiveAt.addingTimeInterval(1)) == second)
        #expect(reset.transitionDates(after: first.effectiveAt) == [second.effectiveAt])
    }

    @Test("app precomputes upcoming grace and expired widget states")
    func resetTimelineBuilderUsesCoreVerdictTransitions() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let scheduledAt = try resetStatusDate("2026-07-28T13:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            event: ResetStatusEventFixture(
                kind: "reset_scheduled",
                announcedAt: "2026-07-28T11:00:00Z",
                effectiveAt: "2026-07-28T13:00:00Z",
                schedulePrecision: "datetime",
                scheduleBasis: "explicit"),
            now: now)
            .decode()

        let widget = snapshot.makeWidgetResetTodaySnapshot(
            now: now,
            calendar: resetStatusUTCCalendar)
        let timeline = try #require(widget.timeline)
        let upcoming = try #require(timeline.first)
        let grace = try #require(timeline.first(where: { $0.reason == .grace }))
        let expired = try #require(timeline.first(where: { $0.reason == .expiredUnconfirmed }))

        #expect(upcoming.reason == .upcoming)
        #expect(upcoming.scheduleBasis == .explicit)
        #expect(upcoming.nextScheduledAt == scheduledAt)
        #expect(grace.effectiveAt == scheduledAt)
        #expect(grace.nextScheduledAt == nil)
        #expect(expired.effectiveAt == scheduledAt.addingTimeInterval(3 * 3_600))
        #expect(expired.confidencePercent == nil)
        #expect(expired.state == .no)
    }

    @Test("widget snapshot stays stable within the same verdict phase")
    func resetTimelineBuilderUsesStableAnchor() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            event: ResetStatusEventFixture(
                kind: "reset_scheduled",
                announcedAt: "2026-07-28T11:00:00Z",
                effectiveAt: "2026-07-28T13:00:00Z",
                schedulePrecision: "datetime"),
            now: now)
            .decode()

        let first = snapshot.makeWidgetResetTodaySnapshot(
            now: now,
            calendar: resetStatusUTCCalendar)
        let second = snapshot.makeWidgetResetTodaySnapshot(
            now: now.addingTimeInterval(10 * 60),
            calendar: resetStatusUTCCalendar)

        #expect(first == second)
    }

    @Test("completed verdict keeps a separate future schedule timer")
    func completedVerdictKeepsFutureTimer() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let future = try resetStatusDate("2026-07-29T13:00:00Z")
        let completed = ResetStatusEventFixture(
            kind: "reset_completed",
            announcedAt: "2026-07-28T11:00:00Z",
            effectiveAt: "2026-07-28T11:00:00Z",
            postID: "100")
        let scheduled = ResetStatusEventFixture(
            kind: "reset_scheduled",
            announcedAt: "2026-07-28T11:30:00Z",
            effectiveAt: "2026-07-29T13:00:00Z",
            schedulePrecision: "datetime",
            postID: "200")
        let snapshot = try ResetStatusFeedFixture(
            eventsJSON: completed.json + "," + scheduled.json,
            now: now)
            .decode()

        let current = try #require(snapshot.makeWidgetResetTodaySnapshot(
            now: now,
            calendar: resetStatusUTCCalendar).timeline?.first)

        #expect(current.reason == .completed)
        #expect(current.nextScheduledAt == future)
        #expect(current.nextScheduledResetType == .global)
    }

    @Test("widget next schedule merges same-time global and banked types")
    func widgetNextScheduleUsesMergedSummary() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let global = ResetStatusEventFixture(
            kind: "reset_scheduled",
            resetType: "global",
            announcedAt: "2026-07-28T11:00:00Z",
            effectiveAt: "2026-07-29T13:00:00Z",
            schedulePrecision: "datetime",
            scheduleBasis: "explicit",
            postID: "200")
        let banked = ResetStatusEventFixture(
            kind: "reset_scheduled",
            resetType: "banked",
            announcedAt: "2026-07-28T11:01:00Z",
            effectiveAt: "2026-07-29T13:00:00Z",
            schedulePrecision: "datetime",
            scheduleBasis: "contextual_inference",
            postID: "201")
        var snapshot = try ResetStatusFeedFixture(
            eventsJSON: global.json + "," + banked.json,
            now: now)
            .decode()
        snapshot.events[0].confidence = 0.91
        snapshot.events[1].confidence = 0.72

        let current = try #require(snapshot.makeWidgetResetTodaySnapshot(
            now: now,
            calendar: resetStatusUTCCalendar).timeline?.first)

        #expect(current.nextScheduledResetType == .globalAndBanked)
        #expect(current.confidencePercent == 72)
        #expect(current.scheduleBasis == .explicit)
    }

    @Test("fractional lifecycle boundary rounds up through ISO second encoding")
    func fractionalBoundaryDoesNotTransitionEarly() throws {
        let now = try resetStatusDate("2026-07-28T12:00:00Z")
        let snapshot = try ResetStatusFeedFixture(
            event: ResetStatusEventFixture(
                kind: "reset_scheduled",
                announcedAt: "2026-07-28T11:00:00Z",
                effectiveAt: "2026-07-28T13:00:00.123Z",
                schedulePrecision: "datetime"),
            now: now)
            .decode()
        let reset = snapshot.makeWidgetResetTodaySnapshot(
            now: now,
            calendar: resetStatusUTCCalendar)
        let container = RunwayWidgetSnapshot(
            generatedAt: now,
            language: .english,
            providers: [],
            resetToday: reset)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            RunwayWidgetSnapshot.self,
            from: encoder.encode(container))
        let decodedReset = try #require(decoded.resetToday)
        let boundary = try resetStatusDate("2026-07-28T13:00:01Z")

        #expect(decodedReset.presentation(at: boundary.addingTimeInterval(-0.001))?.reason == .upcoming)
        #expect(decodedReset.presentation(at: boundary)?.reason == .grace)
        #expect(decodedReset.timeline?.first(where: { $0.reason == .grace })?.effectiveAt == boundary)
    }

    @Test("store writes atomically with owner-only permissions")
    func atomicStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayWidgetSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RunwayWidgetSnapshotStore(
            fileURL: directory.appendingPathComponent(RunwayWidgetSnapshotStore.fileName))

        try store.save(fixture())
        #expect(try store.load() == fixture())
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("store reports missing, corrupt, and unsupported snapshots")
    func storeErrors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayWidgetSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RunwayWidgetSnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))

        #expect(throws: RunwayWidgetSnapshotStoreError.missing) { try store.load() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }

        var unsupported = fixture()
        unsupported.schemaVersion = 99
        try store.save(unsupported)
        #expect(throws: RunwayWidgetSnapshotStoreError.unsupportedSchemaVersion(99)) {
            try store.load()
        }
    }

    @Test("local development storage stays outside App Groups")
    func localDevelopmentStorage() throws {
        let home = URL(fileURLWithPath: "/tmp/runway-widget-home", isDirectory: true)
        let store = try RunwayWidgetSnapshotStore.make(
            mode: .localDevelopment,
            appGroupID: "group.invalid.for-local-development",
            homeDirectory: home)

        #expect(store.fileURL == home
            .appendingPathComponent(".codex-runway", isDirectory: true)
            .appendingPathComponent(RunwayWidgetSnapshotStore.fileName))
    }

    @Test("missing storage mode stays on the local snapshot")
    func missingStorageModeDefaultsToLocal() {
        #expect(RunwayWidgetStorageMode.mode(fromInfoValue: nil) == .localDevelopment)
        #expect(RunwayWidgetStorageMode.mode(fromInfoValue: "nope") == .localDevelopment)
        #expect(RunwayWidgetStorageMode.mode(fromInfoValue: "local") == .localDevelopment)
        #expect(RunwayWidgetStorageMode.mode(fromInfoValue: "app-group") == .appGroup)
    }

    @Test("local launch storage never opens an App Group container")
    func localLaunchStorageDoesNotOpenAppGroup() throws {
        let home = URL(fileURLWithPath: "/tmp/runway-launch-home", isDirectory: true)
        let resolved = try RunwayWidgetLaunchStorage.resolve(
            mode: .localDevelopment,
            appGroupID: "group.com.github.codex-runway",
            homeDirectory: home)

        #expect(resolved.compatibilityStore == nil)
        #expect(resolved.store.fileURL.path.hasPrefix(home.path))
        #expect(!resolved.store.fileURL.pathComponents.contains("Group Containers"))
        #expect(Array(resolved.store.fileURL.pathComponents.suffix(2))
            == [RunwayWidgetSnapshotStore.localDirectoryName, RunwayWidgetSnapshotStore.fileName])
    }

    @Test("standard quota windows sort by duration before model-specific windows")
    func quotaOrdering() {
        let provider = RunwayWidgetProviderSnapshot(
            provider: .codex,
            availability: .available,
            plan: nil,
            updatedAt: nil,
            quota: [
                quota("Model", minutes: 60, source: .modelSpecific),
                quota("Weekly", minutes: 10_080),
                quota("5 hours", minutes: 300),
            ],
            balanceUSD: nil,
            apiEquivalentCostUSD: nil,
            tokenSource: .thisMac,
            dailyTokens: [],
            resetCredits: nil)

        #expect(provider.quota.map(\.windowMinutes) == [300, 10_080, 60])
    }

    @Test("active kinds map to the minimum refresh requirements")
    func requirements() {
        let requirements = RunwayWidgetRequirements.make(activeKinds: [
            RunwayWidgetKind.tokenTrend.rawValue,
            RunwayWidgetKind.resetToday.rawValue,
            "unknown",
        ])
        #expect(requirements.contains(.tokenTrend))
        #expect(requirements.contains(.resetToday))
        #expect(!requirements.contains(.providerQuota))
        #expect(!requirements.contains(.cost))
        #expect(RunwayWidgetRequirements.make(kind: .overview, family: .small) == .providerQuota)
        #expect(RunwayWidgetRequirements.make(kind: .overview, family: .medium) == .providerQuota)
        #expect(RunwayWidgetRequirements.make(kind: .overview, family: .large).contains(.cost))
        #expect(RunwayWidgetRequirements.make(kind: .overview, family: .large).contains(.tokenTrend))
        #expect(RunwayWidgetRequirements.allWidgetData == [
            .providerQuota,
            .tokenTrend,
            .cost,
            .resetToday,
        ])
    }

    @Test("deep links accept only the widget route and known values")
    func deepLinks() {
        let link = RunwayWidgetDeepLink(provider: .both, section: .overview)
        #expect(RunwayWidgetDeepLink(url: link.url) == link)
        #expect(RunwayWidgetDeepLink(url: URL(string: "codex-runway://widget?provider=bad&section=quota")!) == nil)
        #expect(RunwayWidgetDeepLink(url: URL(string: "https://widget?provider=codex&section=quota")!) == nil)
        #expect(RunwayWidgetDeepLink(url: URL(string: "codex-runway://widget?provider=codex&section=quota&extra=1")!) == nil)
    }

    @Test("widget families and timeline match the product contract")
    func layoutPolicy() {
        #expect(RunwayWidgetFamily.allCases.allSatisfy {
            RunwayWidgetLayoutPolicy.supports($0, for: .overview)
        })
        #expect(!RunwayWidgetLayoutPolicy.supports(.small, for: .tokenTrend))
        #expect(RunwayWidgetLayoutPolicy.supports(.medium, for: .tokenTrend))
        #expect(RunwayWidgetLayoutPolicy.supports(.large, for: .tokenTrend))
        #expect(RunwayWidgetLayoutPolicy.supports(.small, for: .metric))
        #expect(!RunwayWidgetLayoutPolicy.supports(.medium, for: .metric))
        #expect(RunwayWidgetLayoutPolicy.supports(.small, for: .resetToday))
        #expect(RunwayWidgetLayoutPolicy.supports(.medium, for: .resetToday))
        #expect(!RunwayWidgetLayoutPolicy.supports(.large, for: .resetToday))
        #expect(RunwayWidgetLayoutPolicy.trendDays(for: .medium) == 14)
        #expect(RunwayWidgetLayoutPolicy.trendDays(for: .large) == 30)
        #expect(RunwayWidgetLayoutPolicy.refreshInterval == 900)
    }

    private func fixture() -> RunwayWidgetSnapshot {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return RunwayWidgetSnapshot(
            generatedAt: date,
            language: .simplifiedChinese,
            providers: [
                RunwayWidgetProviderSnapshot(
                    provider: .codex,
                    availability: .available,
                    plan: "Plus",
                    updatedAt: date,
                    quota: [quota("5 hours", minutes: 300)],
                    balanceUSD: 12.5,
                    apiEquivalentCostUSD: 4.25,
                    tokenSource: .allDevices,
                    dailyTokens: [RunwayWidgetDailyTokens(date: "2026-08-05", tokens: 42)],
                    resetCredits: RunwayWidgetResetCredits(availableCount: 2, expiringCount: 1)),
            ],
            resetToday: RunwayWidgetResetTodaySnapshot(
                state: .unknown,
                resetType: .globalAndBanked,
                nextScheduledAt: date.addingTimeInterval(3_600),
                nextScheduledResetType: .banked,
                lastSuccessfulCheckAt: nil,
                fetchedAt: date,
                confidencePercent: 92,
                confidenceBand: .ok,
                timeline: [
                    RunwayWidgetResetTodayTimelineEntry(
                        effectiveAt: date,
                        reason: .upcoming,
                        state: .yes,
                        resetType: .banked,
                        nextScheduledAt: date.addingTimeInterval(3_600),
                        nextScheduledResetType: .banked,
                        scheduleBasis: .explicit,
                        confidencePercent: 92,
                        confidenceBand: .ok),
                    RunwayWidgetResetTodayTimelineEntry(
                        effectiveAt: date.addingTimeInterval(3_600),
                        reason: .grace,
                        state: .yes,
                        resetType: .banked,
                        nextScheduledAt: nil,
                        nextScheduledResetType: nil,
                        scheduleBasis: .explicit,
                        confidencePercent: 92,
                        confidenceBand: .ok),
                ]))
    }

    private func quota(
        _ title: String,
        minutes: Int,
        source: RunwayWidgetQuotaSource = .standard)
        -> RunwayWidgetQuota
    {
        RunwayWidgetQuota(
            title: title,
            windowMinutes: minutes,
            source: source,
            usedPercent: 25,
            remainingPercent: 75,
            resetsAt: nil)
    }
}
