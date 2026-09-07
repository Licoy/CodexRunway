import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Network proxy settings")
@MainActor
struct NetworkProxySettingsTests {
    @Test("loading settings never reads proxy credentials")
    func initializationDoesNotReadKeychain() throws {
        let name = "NetworkProxySettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let proxyStore = NetworkProxyStore(defaults: defaults)
        let configuration = NetworkProxyConfiguration(
            mode: .http, host: "127.0.0.1", port: 8080,
            usesAuthentication: true, credentialID: UUID().uuidString)
        try proxyStore.save(configuration)
        var reads = [Bool]()
        let credentialStore = ProxyCredentialStore(
            load: { _, interactive in
                reads.append(interactive)
                return NetworkProxyCredentials(username: "test", password: "test")
            },
            save: { _, _ in Issue.record("Unexpected credential write") },
            delete: { _ in Issue.record("Unexpected credential removal") })
        let settings = RunwaySettings(
            store: PreferencesStore(defaults: defaults),
            networkProxyStore: proxyStore, proxyCredentialStore: credentialStore)

        #expect(settings.networkProxy == configuration)
        #expect(settings.proxyError == nil)
        #expect(reads.isEmpty)
        _ = try settings.loadSavedProxyCredentials()
        #expect(reads == [true])
    }

    @Test("malformed proxy settings do not reset unrelated preferences")
    func malformedProxyPreservesPreferences() {
        let name = "NetworkProxySettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferencesStore = PreferencesStore(defaults: defaults)
        var preferences = RunwayPreferences()
        preferences.language = .french
        preferencesStore.save(preferences)
        defaults.set("invalid proxy data", forKey: "runway.networkProxy")
        let settings = RunwaySettings(
            store: preferencesStore, networkProxyStore: NetworkProxyStore(defaults: defaults))

        #expect(settings.proxyError == .invalidConfiguration)
        #expect(settings.preferences.language == .french)
        #expect(defaults.string(forKey: "runway.networkProxy") == "invalid proxy data")
    }

    @Test("failed credential save leaves the previous proxy active and persisted")
    func credentialFailurePreservesOldConfiguration() throws {
        let name = "NetworkProxySettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let proxyStore = NetworkProxyStore(defaults: defaults)
        let previous = NetworkProxyConfiguration(mode: .http, host: "127.0.0.1", port: 8080)
        try proxyStore.save(previous)
        let credentialStore = ProxyCredentialStore(
            load: { _, _ in throw NetworkProxyError.credentialsUnavailable },
            save: { _, _ in throw NetworkProxyError.credentialStoreFailed },
            delete: { _ in Issue.record("Previous credentials must not be removed") })
        let settings = RunwaySettings(
            store: PreferencesStore(defaults: defaults),
            networkProxyStore: proxyStore, proxyCredentialStore: credentialStore)
        var changes = 0
        settings.onChange = { changes += 1 }
        let next = NetworkProxyConfiguration(
            mode: .socks5, host: "127.0.0.1", port: 1080, usesAuthentication: true)

        #expect(throws: NetworkProxyError.credentialStoreFailed) {
            try settings.saveNetworkProxy(next, credentials: NetworkProxyCredentials(username: "test", password: "test"))
        }
        #expect(settings.networkProxy == previous)
        #expect(try proxyStore.load() == previous)
        #expect(changes == 0)
    }

    @Test("draft rejects nonnumeric ports without trimming passwords")
    func draftValidationAndCredentialRetention() throws {
        var draft = NetworkProxyDraft(NetworkProxyConfiguration(mode: .http, host: "localhost", port: 8080))
        draft.port = "8080x"
        #expect(throws: NetworkProxyError.invalidPort) { try draft.configuration() }
        draft.port = " 8080 "
        draft.username = "test"
        draft.password = " password with spaces "
        #expect(try draft.configuration().port == 8080)
        #expect(draft.enteredCredentials?.password == " password with spaces ")
        draft.username = ""
        draft.password = ""
        #expect(draft.enteredCredentials == nil)
        draft.mode = .system
        draft.port = "invalid draft"
        #expect(try draft.configuration() == NetworkProxyConfiguration())
    }
}
