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
                nextScheduledAt: nil,
                lastSuccessfulCheckAt: nil,
                fetchedAt: date))
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
