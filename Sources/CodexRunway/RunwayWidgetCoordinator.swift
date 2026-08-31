import CodexRunwayCore
import Foundation
import WidgetKit

@MainActor
protocol RunwayWidgetTimelineReloading {
    func reloadAllTimelines()
    func reloadTimelines(ofKind kind: String)
}

@MainActor
private struct RunwayWidgetCenterReloader: RunwayWidgetTimelineReloading {
    func reloadAllTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    func reloadTimelines(ofKind kind: String) {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}

struct RunwayWidgetConfiguration: Equatable, Sendable {
    var kind: String
    var family: RunwayWidgetFamily
}

enum RunwayWidgetConfigurationLoadResult: Sendable {
    case success([RunwayWidgetConfiguration])
    case failure(String)
}

@MainActor
protocol RunwayWidgetConfigurationLoading {
    func loadConfigurations(
        completion: @escaping @MainActor @Sendable (RunwayWidgetConfigurationLoadResult) -> Void)
}

@MainActor
private struct RunwayWidgetCenterConfigurationLoader: RunwayWidgetConfigurationLoading {
    func loadConfigurations(
        completion: @escaping @MainActor @Sendable (RunwayWidgetConfigurationLoadResult) -> Void)
    {
        WidgetCenter.shared.getCurrentConfigurations { result in
            let loadResult: RunwayWidgetConfigurationLoadResult = switch result {
            case .success(let configurations):
                .success(configurations.map {
                    RunwayWidgetConfiguration(
                        kind: $0.kind,
                        family: Self.family($0.family))
                })
            case .failure(let error):
                .failure(error.localizedDescription)
            }
            Task { @MainActor in completion(loadResult) }
        }
    }

    nonisolated private static func family(_ family: WidgetFamily) -> RunwayWidgetFamily {
        switch family {
        case .systemSmall: .small
        case .systemLarge: .large
        default: .medium
        }
    }
}

@MainActor
final class RunwayWidgetCoordinator {
    var onRequirementsChanged: ((RunwayWidgetRequirements) -> Void)?
    var initialRequirements: RunwayWidgetRequirements {
        storageMode == .localDevelopment ? .allWidgetData : []
    }

    private let storageMode: RunwayWidgetStorageMode
    private let publisher: RunwayWidgetSnapshotPublisher
    private let reloader: any RunwayWidgetTimelineReloading
    private let configurationLoader: any RunwayWidgetConfigurationLoading
    private var activeKinds: Set<String> = []
    private var configurationLoadGeneration = 0
    private var lastReloadAt: Date?

    convenience init?(bundle: Bundle = .main) {
        let mode = RunwayWidgetStorageMode.mode(
            fromInfoValue: bundle.object(forInfoDictionaryKey: RunwayWidgetStorageMode.infoKey) as? String)
        let appGroupID = bundle.object(
            forInfoDictionaryKey: RunwayWidgetStorageMode.appGroupInfoKey) as? String
        do {
            let storage = try RunwayWidgetLaunchStorage.resolve(
                mode: mode,
                appGroupID: appGroupID)
            self.init(
                storageMode: mode,
                store: storage.store,
                activeKinds: mode == .localDevelopment
                    ? Set(RunwayWidgetKind.allCases.map(\.rawValue))
                    : [],
                reloader: RunwayWidgetCenterReloader(),
                compatibilityStore: storage.compatibilityStore,
                configurationLoader: RunwayWidgetCenterConfigurationLoader())
        } catch {
            NSLog("CodexRunway widget store unavailable: %@", error.localizedDescription)
            return nil
        }
    }

    init(
        storageMode: RunwayWidgetStorageMode,
        store: RunwayWidgetSnapshotStore,
        activeKinds: Set<String>,
        reloader: any RunwayWidgetTimelineReloading,
        compatibilityStore: RunwayWidgetSnapshotStore? = nil,
        configurationLoader: any RunwayWidgetConfigurationLoading)
    {
        self.storageMode = storageMode
        self.publisher = RunwayWidgetSnapshotPublisher(
            store: store,
            compatibilityStore: compatibilityStore)
        self.activeKinds = activeKinds
        self.reloader = reloader
        self.configurationLoader = configurationLoader
    }

    func refreshConfigurations() {
        configurationLoadGeneration += 1
        let generation = configurationLoadGeneration
        configurationLoader.loadConfigurations { [weak self] result in
            guard let self, self.configurationLoadGeneration == generation else { return }
            switch result {
            case .success(let configurations):
                self.activeKinds = Set(configurations.map(\.kind))
                let requirements = configurations.reduce(into: RunwayWidgetRequirements()) {
                    result, configuration in
                    guard let kind = RunwayWidgetKind(rawValue: configuration.kind) else { return }
                    result.formUnion(.make(
                        kind: kind,
                        family: configuration.family))
                }
                self.onRequirementsChanged?(requirements)
            case .failure(let message):
                NSLog("CodexRunway could not inspect widgets: %@", message)
            }
        }
    }

    @discardableResult
    func publish(
        _ snapshot: RunwayWidgetSnapshot,
        force: Bool = false,
        reloadTimelines: Bool = true,
        minimumReloadInterval: TimeInterval = 0
    ) -> Task<Void, Never> {
        Task { @MainActor [publisher] in
            do {
                guard try await publisher.publish(snapshot, force: force) else { return }
                guard reloadTimelines else {
                    recordReload(at: snapshot.generatedAt)
                    return
                }
                if force {
                    reloader.reloadAllTimelines()
                    recordReload(at: snapshot.generatedAt)
                } else {
                    guard shouldReload(
                        snapshot,
                        minimumInterval: minimumReloadInterval),
                        !activeKinds.isEmpty
                    else { return }
                    for kind in activeKinds {
                        reloader.reloadTimelines(ofKind: kind)
                    }
                    recordReload(at: snapshot.generatedAt)
                }
            } catch {
                NSLog("CodexRunway could not publish widget data: %@", error.localizedDescription)
            }
        }
    }

    private func shouldReload(
        _ snapshot: RunwayWidgetSnapshot,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let lastReloadAt else { return true }
        return snapshot.generatedAt.timeIntervalSince(lastReloadAt) >= minimumInterval
    }

    private func recordReload(at date: Date) {
        lastReloadAt = max(lastReloadAt ?? .distantPast, date)
    }

}

private actor RunwayWidgetSnapshotPublisher {
    private let store: RunwayWidgetSnapshotStore
    private let compatibilityStore: RunwayWidgetSnapshotStore?
    private var lastSnapshot: RunwayWidgetSnapshot?

    init(
        store: RunwayWidgetSnapshotStore,
        compatibilityStore: RunwayWidgetSnapshotStore?)
    {
        self.store = store
        self.compatibilityStore = compatibilityStore
    }

    func publish(_ snapshot: RunwayWidgetSnapshot, force: Bool) throws -> Bool {
        if let previous = lastSnapshot {
            guard snapshot.generatedAt >= previous.generatedAt else { return false }
            if !force {
                var comparable = previous
                comparable.generatedAt = snapshot.generatedAt
                if comparable == snapshot { return false }
            }
        }
        try store.save(snapshot)
        lastSnapshot = snapshot
        if let compatibilityStore {
            do {
                try compatibilityStore.save(snapshot)
            } catch {
                NSLog("CodexRunway could not mirror widget data: %@", error.localizedDescription)
            }
        }
        return true
    }
}
