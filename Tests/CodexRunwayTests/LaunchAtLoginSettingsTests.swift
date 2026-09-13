import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Launch at login settings")
@MainActor
struct LaunchAtLoginSettingsTests {
    @Test("settings toggle persist-and-applies enabled then disabled")
    func togglePersistsAndApplies() {
        let backend = SettingsLoginItemBackend()
        let (settings, store, suite) = makeSettings(backend: backend)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        #expect(settings.preferences.launchAtLoginEnabled)
        settings.applyStoredLaunchAtLogin()
        #expect(backend.calls == [.register])
        #expect(backend.isEnabled)

        settings.updateLaunchAtLogin(true)
        #expect(settings.preferences.launchAtLoginEnabled)
        #expect(store.load().launchAtLoginEnabled)
        #expect(backend.calls == [.register, .register])

        settings.updateLaunchAtLogin(false)
        #expect(!settings.preferences.launchAtLoginEnabled)
        #expect(!store.load().launchAtLoginEnabled)
        #expect(backend.calls == [.register, .register, .unregister])
        #expect(!backend.isEnabled)
        #expect(settings.loginItemError == nil)
        #expect(store.load().launchAtLoginInitialized)
        settings.applyStoredLaunchAtLogin()
        #expect(backend.calls == [.register, .register, .unregister])
    }

    @Test("failed register does not persist enabled")
    func failedRegisterLeavesPreferenceOff() {
        let backend = SettingsLoginItemBackend()
        let suite = "LaunchAtLoginFailed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        store.save(RunwayPreferences(launchAtLoginEnabled: false))
        let settings = RunwaySettings(
            store: store,
            loginItemApplier: LoginItemApplier(backend: backend, canMutateSystem: true))
        backend.registerError = LoginItemError.registerFailed

        settings.updateLaunchAtLogin(true)

        #expect(!settings.preferences.launchAtLoginEnabled)
        #expect(!store.load().launchAtLoginEnabled)
        #expect(settings.loginItemError == .registerFailed)
        #expect(backend.calls == [.register])
        #expect(!backend.isEnabled)
    }

    @Test("development hosts neither register nor consume first-launch setup")
    func unpackagedSkipsSetup() {
        let backend = SettingsLoginItemBackend()
        let (settings, store, suite) = makeSettings(
            backend: backend,
            canMutateSystem: false)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        settings.applyStoredLaunchAtLogin()
        settings.updateLaunchAtLogin(false)
        #expect(settings.preferences.launchAtLoginEnabled)
        #expect(store.load().launchAtLoginEnabled)
        #expect(!store.load().launchAtLoginInitialized)
        #expect(settings.loginItemStatus == .unavailable)
        #expect(settings.launchAtLoginDescriptionKey == .launchAtLoginUnavailable)
        #expect(backend.calls.isEmpty)
        #expect(settings.loginItemError == nil)

        settings.updateLaunchAtLogin(true)
        #expect(settings.preferences.launchAtLoginEnabled)
        #expect(store.load().launchAtLoginEnabled)
        #expect(backend.calls.isEmpty)
    }

    @Test("system changes survive refresh and the next app launch")
    func externalChangesAreRespected() {
        let backend = SettingsLoginItemBackend()
        let (settings, store, suite) = makeSettings(backend: backend)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        settings.applyStoredLaunchAtLogin()
        backend.currentStatus = .notRegistered

        let reopened = RunwaySettings(
            store: store,
            loginItemApplier: LoginItemApplier(backend: backend, canMutateSystem: true))
        reopened.applyStoredLaunchAtLogin()
        #expect(reopened.loginItemStatus == .notRegistered)
        #expect(!store.load().launchAtLoginEnabled)
        #expect(backend.calls == [.register])

        backend.currentStatus = .enabled
        reopened.refreshLaunchAtLoginStatus()
        #expect(reopened.loginItemStatus == .enabled)
        #expect(store.load().launchAtLoginEnabled)
        #expect(backend.calls == [.register])
    }

    @Test("approval is visible, refreshable, and can be cancelled")
    func approvalLifecycle() {
        let backend = SettingsLoginItemBackend()
        backend.registrationStatus = .requiresApproval
        let (settings, store, suite) = makeSettings(backend: backend)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        settings.applyStoredLaunchAtLogin()
        #expect(settings.loginItemStatus == .requiresApproval)
        #expect(settings.launchAtLoginDescriptionKey == .launchAtLoginRequiresApproval)
        #expect(store.load().launchAtLoginInitialized)
        settings.applyStoredLaunchAtLogin()
        #expect(backend.calls == [.register])

        backend.currentStatus = .enabled
        settings.refreshLaunchAtLoginStatus()
        #expect(settings.loginItemStatus == .enabled)
        #expect(settings.launchAtLoginDescriptionKey == .launchAtLoginDescription)

        backend.currentStatus = .requiresApproval
        settings.refreshLaunchAtLoginStatus()
        settings.updateLaunchAtLogin(false)
        #expect(settings.loginItemStatus == .notRegistered)
        #expect(!store.load().launchAtLoginEnabled)
        #expect(backend.calls == [.register, .unregister])
    }

    @Test("failed default registration stays retryable and failed removal stays enabled")
    func failuresDoNotPersistSuccess() {
        let backend = SettingsLoginItemBackend()
        backend.registerError = LoginItemError.registerFailed
        let (settings, store, suite) = makeSettings(backend: backend)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        settings.applyStoredLaunchAtLogin()
        #expect(settings.loginItemStatus == .notRegistered)
        #expect(settings.loginItemError == .registerFailed)
        #expect(!store.load().launchAtLoginInitialized)
        settings.refreshLaunchAtLoginStatus()
        #expect(settings.loginItemError == .registerFailed)
        #expect(settings.launchAtLoginDescriptionKey == .launchAtLoginFailed)

        backend.registerError = nil
        settings.updateLaunchAtLogin(true)
        #expect(store.load().launchAtLoginInitialized)
        backend.unregisterError = LoginItemError.unregisterFailed
        settings.updateLaunchAtLogin(false)
        #expect(settings.loginItemStatus == .enabled)
        #expect(settings.loginItemError == .unregisterFailed)
        #expect(settings.launchAtLoginDescriptionKey == .launchAtLoginFailed)
        #expect(store.load().launchAtLoginEnabled)
        settings.refreshLaunchAtLoginStatus()
        #expect(settings.loginItemError == .unregisterFailed)
        backend.currentStatus = .notRegistered
        settings.refreshLaunchAtLoginStatus()
        #expect(settings.loginItemError == nil)
        #expect(!store.load().launchAtLoginEnabled)
    }

    @Test("status failure never changes a saved preference or attempts registration")
    func statusFailureDoesNotMutate() {
        let backend = SettingsLoginItemBackend()
        backend.statusError = .statusUnavailable
        let (settings, store, suite) = makeSettings(backend: backend)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        settings.applyStoredLaunchAtLogin()
        #expect(settings.loginItemError == .statusUnavailable)
        #expect(!store.load().launchAtLoginInitialized)
        #expect(backend.calls.isEmpty)
        backend.statusError = nil
        settings.updateLaunchAtLogin(true)
        backend.statusError = .statusUnavailable
        settings.refreshLaunchAtLoginStatus()
        #expect(settings.loginItemError == .statusUnavailable)
        #expect(store.load().launchAtLoginEnabled)
        #expect(backend.calls == [.register])
    }

    @Test("production host policy excludes swift run and its development app wrapper")
    func productionHostPolicy() {
        let app = URL(fileURLWithPath: "/Applications/CodexRunway.app")
        #expect(LoginItemApplier.supportsHost(bundleURL: app, bundleIdentifier: "com.github.codex-runway"))
        #expect(!LoginItemApplier.supportsHost(bundleURL: app, bundleIdentifier: "com.github.codex-runway.swift-dev"))
        #expect(!LoginItemApplier.supportsHost(bundleURL: app, bundleIdentifier: nil))
        #expect(!LoginItemApplier.supportsHost(
            bundleURL: URL(fileURLWithPath: "/tmp/debug"), bundleIdentifier: "com.github.codex-runway"))
    }

    @Test("general pane hosts the launch-at-login control via L10n")
    func generalPaneHostsLaunchAtLoginControl() throws {
        let source = try String(contentsOf: sourceURL("ControlPanelView.swift"), encoding: .utf8)
        let general = try pane(source, named: "generalPane", until: "displayPane")
        let advanced = try pane(source, named: "advancedPane", until: "aboutPane")
        let about = try pane(source, named: "aboutPane", until: "openCodexFolder")

        #expect(general.contains("l10n.text(.launchAtLogin)"))
        #expect(general.contains("l10n.text(settings.launchAtLoginDescriptionKey)"))
        #expect(general.contains("settings.loginItemStatus == .requiresApproval"))
        #expect(general.contains("l10n.text(.openLoginItemsSettings)"))
        #expect(general.contains("SMAppService.openSystemSettingsLoginItems()"))
        #expect(general.contains("launchAtLoginBinding"))
        #expect(general.contains("PreferenceToggleRow("))
        #expect(!advanced.contains("launchAtLogin"))
        #expect(!about.contains("launchAtLogin"))
        #expect(!source.contains("\"Launch at login\""))
        #expect(!source.contains("\"开机自启\""))
        #expect(source.contains("NSApplication.didBecomeActiveNotification"))
        #expect(source.contains(".onAppear { settings.refreshLaunchAtLoginStatus() }"))

        let status = try String(contentsOf: sourceURL("StatusController.swift"), encoding: .utf8)
        #expect(status.contains("settings.applyStoredLaunchAtLogin()"))

        let backend = try String(contentsOf: sourceURL("SystemLoginItemBackend.swift"), encoding: .utf8)
        #expect(backend.contains("SMAppService.mainApp"))
        #expect(backend.contains("kLSSharedFileListSessionLoginItems"))
        #expect(backend.contains("#available(macOS 13.0, *)"))
    }

    private func makeSettings(
        backend: SettingsLoginItemBackend,
        canMutateSystem: Bool = true
    ) -> (RunwaySettings, PreferencesStore, String) {
        let suite = "LaunchAtLoginSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = PreferencesStore(defaults: defaults)
        let settings = RunwaySettings(
            store: store,
            loginItemApplier: LoginItemApplier(
                backend: backend,
                canMutateSystem: canMutateSystem))
        return (settings, store, suite)
    }

    private func pane(_ source: String, named name: String, until next: String) throws -> String {
        guard let start = source.range(of: "private var \(name)") else {
            throw PaneExtractionError.missing(name)
        }
        let rest = start.upperBound..<source.endIndex
        let end = source.range(of: "private var \(next)", range: rest)
            ?? source.range(of: "private func \(next)", range: rest)
        guard let end else { throw PaneExtractionError.missing(next) }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexRunway/\(name)")
    }
}

private enum PaneExtractionError: Error {
    case missing(String)
}

final class SettingsLoginItemBackend: LoginItemBackend {
    enum Call: Equatable {
        case register
        case unregister
    }

    private(set) var calls: [Call] = []
    var currentStatus: LoginItemStatus = .notRegistered
    var registrationStatus: LoginItemStatus = .enabled
    var isEnabled: Bool { currentStatus == .enabled }
    var registerError: Error?
    var unregisterError: Error?
    var statusError: LoginItemError?

    func status() throws -> LoginItemStatus {
        if let statusError { throw statusError }
        return currentStatus
    }

    func register() throws {
        calls.append(.register)
        if let registerError { throw registerError }
        currentStatus = registrationStatus
    }

    func unregister() throws {
        calls.append(.unregister)
        if let unregisterError { throw unregisterError }
        currentStatus = .notRegistered
    }
}
