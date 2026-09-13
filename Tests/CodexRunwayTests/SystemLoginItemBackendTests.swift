import Foundation
import ServiceManagement
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("System login item status")
@MainActor
struct SystemLoginItemBackendTests {
    @Test("a missing main-app record allows default startup registration")
    func missingRecordAllowsDefaultRegistration() throws {
        guard #available(macOS 13.0, *) else { return }
        let backend = SettingsLoginItemBackend()
        backend.currentStatus = try SystemLoginItemBackend.loginItemStatus(for: .notFound)
        let suite = "LoginItemMissingRecord-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        let settings = RunwaySettings(
            store: store,
            loginItemApplier: LoginItemApplier(backend: backend, canMutateSystem: true))

        settings.applyStoredLaunchAtLogin()

        #expect(backend.calls == [.register])
        #expect(settings.loginItemStatus == .enabled)
        #expect(settings.loginItemError == nil)
        #expect(store.load().launchAtLoginEnabled)
        #expect(store.load().launchAtLoginInitialized)
    }

    @Test("native registration and approval states stay distinct")
    func mapsSystemStatus() throws {
        guard #available(macOS 13.0, *) else { return }
        #expect(try SystemLoginItemBackend.loginItemStatus(for: .notRegistered) == .notRegistered)
        #expect(try SystemLoginItemBackend.loginItemStatus(for: .enabled) == .enabled)
        #expect(try SystemLoginItemBackend.loginItemStatus(for: .requiresApproval) == .requiresApproval)
    }
}
