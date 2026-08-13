import CodexRunwayCore
import Foundation
import Testing
@testable import CodexRunway

@Suite("Runway widget coordinator")
@MainActor
struct RunwayWidgetCoordinatorTests {
    @Test("host launch storage never probes App Group containers")
    func hostLaunchStorageNeverProbesAppGroup() throws {
        let resolved = try RunwayWidgetLaunchStorage.resolve(
            mode: .localDevelopment,
            appGroupID: "group.com.github.codex-runway",
            homeDirectory: URL(fileURLWithPath: "/tmp/runway-coordinator-home", isDirectory: true))
        #expect(resolved.compatibilityStore == nil)
        #expect(!resolved.store.fileURL.pathComponents.contains("Group Containers"))
    }

    @Test("local startup stays conservative until an empty configuration query clears widget work")
    func emptyLocalConfigurationClearsWidgetWork() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let reloadSpy = WidgetReloadSpy()
        let configurationLoader = WidgetConfigurationLoaderStub(result: .success([]))
        let coordinator = makeCoordinator(
            store: fixture.store,
            reloadSpy: reloadSpy,
            activeKinds: Set(RunwayWidgetKind.allCases.map(\.rawValue)),
            configurationLoader: configurationLoader)
        var observedRequirements: [RunwayWidgetRequirements] = []
        coordinator.onRequirementsChanged = { observedRequirements.append($0) }

        #expect(coordinator.initialRequirements == .allWidgetData)

        coordinator.refreshConfigurations()
        await coordinator.publish(
            makeSnapshot(generatedAt: Date(timeIntervalSince1970: 500))).value

        #expect(configurationLoader.loadCount == 1)
        #expect(observedRequirements == [RunwayWidgetRequirements()])
        #expect(reloadSpy.reloadAllCount == 0)
        #expect(reloadSpy.reloadedKinds.isEmpty)
    }

    @Test("local configuration failure preserves conservative widget work")
    func failedLocalConfigurationPreservesWidgetWork() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let reloadSpy = WidgetReloadSpy()
        let configurationLoader = WidgetConfigurationLoaderStub(
            result: .failure("configuration lookup failed"))
        let coordinator = makeCoordinator(
            store: fixture.store,
            reloadSpy: reloadSpy,
            activeKinds: Set(RunwayWidgetKind.allCases.map(\.rawValue)),
            configurationLoader: configurationLoader)
        var observedRequirements: [RunwayWidgetRequirements] = []
        coordinator.onRequirementsChanged = { observedRequirements.append($0) }

        coordinator.refreshConfigurations()
        await coordinator.publish(
            makeSnapshot(generatedAt: Date(timeIntervalSince1970: 750))).value

        #expect(configurationLoader.loadCount == 1)
        #expect(observedRequirements.isEmpty)
        #expect(Set(reloadSpy.reloadedKinds) == Set(RunwayWidgetKind.allCases.map(\.rawValue)))
    }

    @Test("an older configuration result cannot replace a newer one")
    func staleConfigurationResultIsIgnored() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let reloadSpy = WidgetReloadSpy()
        let configurationLoader = DeferredWidgetConfigurationLoader()
        let coordinator = makeCoordinator(
            store: fixture.store,
            reloadSpy: reloadSpy,
            activeKinds: [],
            configurationLoader: configurationLoader)
        var observedRequirements: [RunwayWidgetRequirements] = []
        coordinator.onRequirementsChanged = { observedRequirements.append($0) }

        coordinator.refreshConfigurations()
        coordinator.refreshConfigurations()
        configurationLoader.complete(
            at: 1,
            with: .success([RunwayWidgetConfiguration(
                kind: RunwayWidgetKind.overview.rawValue,
                family: .small)]))
        configurationLoader.complete(at: 0, with: .success([]))

        await coordinator.publish(
            makeSnapshot(generatedAt: Date(timeIntervalSince1970: 900))).value

        #expect(observedRequirements == [.providerQuota])
        #expect(reloadSpy.reloadedKinds == [RunwayWidgetKind.overview.rawValue])
    }

    @Test("forced publish writes the snapshot and reloads every timeline")
    func forcedPublishReloadsEveryTimeline() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let compatibilityFixture = try makeFixture()
        defer { compatibilityFixture.cleanup() }
        let reloadSpy = WidgetReloadSpy()
        let coordinator = makeCoordinator(
            store: fixture.store,
            reloadSpy: reloadSpy,
            activeKinds: [],
            compatibilityStore: compatibilityFixture.store)
        let snapshot = makeSnapshot(generatedAt: Date(timeIntervalSince1970: 1_000))

        await coordinator.publish(snapshot, force: true).value

        #expect(try fixture.store.load().generatedAt == snapshot.generatedAt)
        #expect(try compatibilityFixture.store.load().generatedAt == snapshot.generatedAt)
        #expect(reloadSpy.reloadAllCount == 1)
        #expect(reloadSpy.reloadedKinds.isEmpty)
    }

    @Test("a forced publish can write snapshots without reloading timelines")
    func forcedPublishCanSkipTimelineReload() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let compatibilityFixture = try makeFixture()
        defer { compatibilityFixture.cleanup() }
        let reloadSpy = WidgetReloadSpy()
        let coordinator = makeCoordinator(
            store: fixture.store,
            reloadSpy: reloadSpy,
            activeKinds: [],
            compatibilityStore: compatibilityFixture.store)
        let snapshot = makeSnapshot(generatedAt: Date(timeIntervalSince1970: 1_100))

        await coordinator.publish(
            snapshot,
            force: true,
            reloadTimelines: false).value

        #expect(try fixture.store.load() == snapshot)
        #expect(try compatibilityFixture.store.load() == snapshot)
        #expect(reloadSpy.reloadAllCount == 0)
        #expect(reloadSpy.reloadedKinds.isEmpty)
    }

    @Test("failed cleanup suppresses startup and first-refresh reloads before cadence resumes")
    func failedCleanupDefersReloadUntilLaterCadence() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let reloadSpy = WidgetReloadSpy()
        let coordinator = makeCoordinator(store: fixture.store, reloadSpy: reloadSpy)
        var gate = RunwayWidgetReloadGate(initiallyAllowed: false)
        let startup = makeSnapshot(generatedAt: Date(timeIntervalSince1970: 1_000))
        await coordinator.publish(
            startup,
            force: true,
            reloadTimelines: gate.allowsReload,
            minimumReloadInterval: 60).value
        let firstRefresh = makeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_010),
            remainingPercent: 70)
        await coordinator.publish(
            firstRefresh,
            force: true,
            reloadTimelines: gate.allowsReload,
            minimumReloadInterval: 60).value

        gate.open()
        let early = makeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_040),
            remainingPercent: 60)
        await coordinator.publish(
            early,
            reloadTimelines: gate.allowsReload,
            minimumReloadInterval: 60).value

        #expect(try fixture.store.load() == early)
        #expect(reloadSpy.reloadAllCount == 0)
        #expect(reloadSpy.reloadedKinds.isEmpty)

        let due = makeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_070),
            remainingPercent: 50)
        await coordinator.publish(
            due,
            reloadTimelines: gate.allowsReload,
            minimumReloadInterval: 60).value

        #expect(try fixture.store.load() == due)
        #expect(Set(reloadSpy.reloadedKinds) == activeKinds)
    }

    @Test("a late older forced publish cannot replace a newer snapshot")
    func lateOlderForcedPublishIsRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let compatibilityFixture = try makeFixture()
        defer { compatibilityFixture.cleanup() }
        let reloadSpy = WidgetReloadSpy()
        let coordinator = makeCoordinator(
            store: fixture.store,
            reloadSpy: reloadSpy,
            compatibilityStore: compatibilityFixture.store)
        let older = makeSnapshot(generatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000),
            remainingPercent: 40)

        await coordinator.publish(newer, force: true).value
        await coordinator.publish(older, force: true).value

        #expect(try fixture.store.load() == newer)
        #expect(try compatibilityFixture.store.load() == newer)
        #expect(reloadSpy.reloadAllCount == 1)

        await coordinator.publish(newer, force: true).value
        #expect(reloadSpy.reloadAllCount == 2)
    }

    @Test("compatibility write failure does not block forced reload")
    func compatibilityFailureDoesNotBlockReload() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let blockedDirectory = fixture.directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedDirectory)
        let compatibilityStore = RunwayWidgetSnapshotStore(
            fileURL: blockedDirectory.appendingPathComponent(RunwayWidgetSnapshotStore.fileName))
        let reloadSpy = WidgetReloadSpy()
        let coordinator = makeCoordinator(
            store: fixture.store,
            reloadSpy: reloadSpy,
            activeKinds: [],
            compatibilityStore: compatibilityStore)
        let snapshot = makeSnapshot(generatedAt: Date(timeIntervalSince1970: 1_500))

        await coordinator.publish(snapshot, force: true).value

        #expect(try fixture.store.load() == snapshot)
        #expect(reloadSpy.reloadAllCount == 1)
    }

    @Test("non-forced data changes reload only active widget kinds")
    func changedPublishReloadsActiveKinds() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let reloadSpy = WidgetReloadSpy()
        let coordinator = makeCoordinator(store: fixture.store, reloadSpy: reloadSpy)
        let initial = makeSnapshot(generatedAt: Date(timeIntervalSince1970: 2_000))
        await coordinator.publish(initial).value
        reloadSpy.reset()
        let changed = makeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_060),
            remainingPercent: 40)

        await coordinator.publish(changed).value

        #expect(try fixture.store.load() == changed)
        #expect(reloadSpy.reloadAllCount == 0)
        #expect(Set(reloadSpy.reloadedKinds) == activeKinds)
    }

    @Test("minimum interval throttles reloads without dropping newer snapshots")
    func minimumIntervalThrottlesReloads() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let reloadSpy = WidgetReloadSpy()
        let coordinator = makeCoordinator(store: fixture.store, reloadSpy: reloadSpy)
        let initial = makeSnapshot(generatedAt: Date(timeIntervalSince1970: 4_000))
        await coordinator.publish(initial, minimumReloadInterval: 300).value
        reloadSpy.reset()
        let early = makeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 4_060),
            remainingPercent: 60)

        await coordinator.publish(early, minimumReloadInterval: 300).value

        #expect(try fixture.store.load() == early)
        #expect(reloadSpy.reloadedKinds.isEmpty)

        let due = makeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 4_300),
            remainingPercent: 40)
        await coordinator.publish(due, minimumReloadInterval: 300).value

        #expect(try fixture.store.load() == due)
        #expect(Set(reloadSpy.reloadedKinds) == activeKinds)
    }

    @Test("non-forced generated-at-only changes neither write nor reload")
    func timestampOnlyPublishIsSkipped() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let reloadSpy = WidgetReloadSpy()
        let coordinator = makeCoordinator(store: fixture.store, reloadSpy: reloadSpy)
        let initial = makeSnapshot(generatedAt: Date(timeIntervalSince1970: 3_000))
        await coordinator.publish(initial).value
        reloadSpy.reset()
        var timestampOnly = initial
        timestampOnly.generatedAt = Date(timeIntervalSince1970: 3_060)

        await coordinator.publish(timestampOnly).value

        #expect(try fixture.store.load() == initial)
        #expect(reloadSpy.reloadAllCount == 0)
        #expect(reloadSpy.reloadedKinds.isEmpty)
    }

    private var activeKinds: Set<String> {
        [
            RunwayWidgetKind.overview.rawValue,
            RunwayWidgetKind.metric.rawValue,
        ]
    }

    private func makeCoordinator(
        store: RunwayWidgetSnapshotStore,
        reloadSpy: WidgetReloadSpy,
        activeKinds: Set<String>? = nil,
        compatibilityStore: RunwayWidgetSnapshotStore? = nil,
        configurationLoader: (any RunwayWidgetConfigurationLoading)? = nil
    ) -> RunwayWidgetCoordinator {
        RunwayWidgetCoordinator(
            storageMode: .localDevelopment,
            store: store,
            activeKinds: activeKinds ?? self.activeKinds,
            reloader: reloadSpy,
            compatibilityStore: compatibilityStore,
            configurationLoader: configurationLoader
                ?? WidgetConfigurationLoaderStub(result: .success([])))
    }

    private func makeFixture() throws -> StoreFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayWidgetCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        return StoreFixture(
            directory: directory,
            store: RunwayWidgetSnapshotStore(
                fileURL: directory.appendingPathComponent(RunwayWidgetSnapshotStore.fileName)))
    }

    private func makeSnapshot(
        generatedAt: Date,
        remainingPercent: Int = 75
    ) -> RunwayWidgetSnapshot {
        RunwayWidgetSnapshot(
            generatedAt: generatedAt,
            language: .english,
            providers: [
                RunwayWidgetProviderSnapshot(
                    provider: .codex,
                    availability: .available,
                    plan: "pro",
                    updatedAt: nil,
                    quota: [
                        RunwayWidgetQuota(
                            title: "5 hours",
                            windowMinutes: 300,
                            source: .standard,
                            usedPercent: 100 - remainingPercent,
                            remainingPercent: remainingPercent,
                            resetsAt: nil),
                    ],
                    balanceUSD: nil,
                    apiEquivalentCostUSD: nil,
                    tokenSource: .thisMac,
                    dailyTokens: [],
                    resetCredits: nil),
            ],
            resetToday: nil)
    }
}

private struct StoreFixture {
    let directory: URL
    let store: RunwayWidgetSnapshotStore

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class WidgetReloadSpy: RunwayWidgetTimelineReloading {
    private(set) var reloadAllCount = 0
    private(set) var reloadedKinds: [String] = []

    func reloadAllTimelines() {
        reloadAllCount += 1
    }

    func reloadTimelines(ofKind kind: String) {
        reloadedKinds.append(kind)
    }

    func reset() {
        reloadAllCount = 0
        reloadedKinds = []
    }
}

@MainActor
private final class WidgetConfigurationLoaderStub: RunwayWidgetConfigurationLoading {
    var result: RunwayWidgetConfigurationLoadResult
    private(set) var loadCount = 0

    init(result: RunwayWidgetConfigurationLoadResult) {
        self.result = result
    }

    func loadConfigurations(
        completion: @escaping @MainActor @Sendable (RunwayWidgetConfigurationLoadResult) -> Void)
    {
        loadCount += 1
        completion(result)
    }
}

@MainActor
private final class DeferredWidgetConfigurationLoader: RunwayWidgetConfigurationLoading {
    private var completions: [
        @MainActor @Sendable (RunwayWidgetConfigurationLoadResult) -> Void
    ] = []

    func loadConfigurations(
        completion: @escaping @MainActor @Sendable (RunwayWidgetConfigurationLoadResult) -> Void
    ) {
        completions.append(completion)
    }

    func complete(at index: Int, with result: RunwayWidgetConfigurationLoadResult) {
        completions[index](result)
    }
}
