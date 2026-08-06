import CodexRunwayCore
import Foundation
import WidgetKit

@MainActor
final class RunwayWidgetCoordinator {
    var onRequirementsChanged: ((RunwayWidgetRequirements) -> Void)?
    var initialRequirements: RunwayWidgetRequirements {
        storageMode == .localDevelopment ? .allWidgetData : []
    }

    private let storageMode: RunwayWidgetStorageMode
    private let publisher: RunwayWidgetSnapshotPublisher
    private var activeKinds: Set<String> = []

    init?(bundle: Bundle = .main) {
        let mode = (bundle.object(forInfoDictionaryKey: RunwayWidgetStorageMode.infoKey) as? String)
            .flatMap(RunwayWidgetStorageMode.init(rawValue:))
            ?? .appGroup
        let appGroupID = bundle.object(
            forInfoDictionaryKey: RunwayWidgetStorageMode.appGroupInfoKey) as? String
        do {
            let store = try RunwayWidgetSnapshotStore.make(
                mode: mode,
                appGroupID: appGroupID)
            storageMode = mode
            publisher = RunwayWidgetSnapshotPublisher(store: store)
            if mode == .localDevelopment {
                activeKinds = Set(RunwayWidgetKind.allCases.map(\.rawValue))
            }
        } catch {
            NSLog("Codex Runway widget store unavailable: %@", error.localizedDescription)
            return nil
        }
    }

    func refreshConfigurations() {
        if storageMode == .localDevelopment {
            activeKinds = Set(RunwayWidgetKind.allCases.map(\.rawValue))
            onRequirementsChanged?(.allWidgetData)
            return
        }
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let configurations):
                    self.activeKinds = Set(configurations.map(\.kind))
                    let requirements = configurations.reduce(into: RunwayWidgetRequirements()) {
                        result, configuration in
                        guard let kind = RunwayWidgetKind(rawValue: configuration.kind) else { return }
                        result.formUnion(.make(
                            kind: kind,
                            family: Self.family(configuration.family)))
                    }
                    self.onRequirementsChanged?(requirements)
                case .failure(let error):
                    NSLog("Codex Runway could not inspect widgets: %@", error.localizedDescription)
                }
            }
        }
    }

    func publish(_ snapshot: RunwayWidgetSnapshot, force: Bool = false) {
        Task { [publisher] in
            do {
                guard try await publisher.publish(snapshot, force: force) else { return }
                for kind in activeKinds {
                    WidgetCenter.shared.reloadTimelines(ofKind: kind)
                }
            } catch {
                NSLog("Codex Runway could not publish widget data: %@", error.localizedDescription)
            }
        }
    }

    private static func family(_ family: WidgetFamily) -> RunwayWidgetFamily {
        switch family {
        case .systemSmall: .small
        case .systemLarge: .large
        default: .medium
        }
    }
}

private actor RunwayWidgetSnapshotPublisher {
    private let store: RunwayWidgetSnapshotStore
    private var lastSnapshot: RunwayWidgetSnapshot?

    init(store: RunwayWidgetSnapshotStore) {
        self.store = store
    }

    func publish(_ snapshot: RunwayWidgetSnapshot, force: Bool) throws -> Bool {
        if !force, var previous = lastSnapshot {
            previous.generatedAt = snapshot.generatedAt
            if previous == snapshot { return false }
        }
        try store.save(snapshot)
        lastSnapshot = snapshot
        return true
    }
}
