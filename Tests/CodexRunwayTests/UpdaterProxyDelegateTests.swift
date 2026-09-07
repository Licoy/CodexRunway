import Foundation
import Sparkle
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Sparkle proxy delegate selectors")
@MainActor
struct UpdaterProxyDelegateTests {
    @Test("Sparkle calls the real release-note, cycle, and download overrides")
    func exportedSelectors() {
        for selector in [
            "updater:shouldDownloadReleaseNotesForUpdate:",
            "updater:mayPerformUpdateCheck:error:",
            "updater:willDownloadUpdate:withRequest:",
            "updater:didFinishUpdateCycleForUpdateCheck:error:",
        ] {
            #expect(UpdaterService.instancesRespond(to: NSSelectorFromString(selector)))
        }
    }

    @Test("driver reentry keeps the original system cycle until Sparkle finishes it")
    func reentrantCycleKeepsContext() throws {
        let name = "UpdaterProxyCycle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = RunwaySettings(
            store: PreferencesStore(defaults: defaults), networkProxyStore: NetworkProxyStore(defaults: defaults))
        let service = UpdaterService(settings: settings)
        defer { service.stop() }
        let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: RunwaySparkleUserDriver(settings: settings), delegate: nil)
        let initial = try RunwayNetworkContext()
        try RunwayNetwork.$scopedContext.withValue(initial) {
            try service.updater(updater, mayPerform: .updatesInBackground)
        }
        let changed = try RunwayNetworkContext(configuration: NetworkProxyConfiguration(mode: .http, host: "127.0.0.1", port: 7890))
        try RunwayNetwork.$scopedContext.withValue(changed) {
            try service.updater(updater, mayPerform: .updates)
            #expect(service.feedURLString(for: updater)?.hasPrefix("https://github.com/") == true)
            service.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
            #expect(throws: (any Error).self) { try service.updater(updater, mayPerform: .updates) }
        }
    }
}
