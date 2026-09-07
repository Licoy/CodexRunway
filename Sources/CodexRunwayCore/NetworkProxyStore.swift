import Foundation

/// Kept separate from general preferences: malformed proxy settings must never enable direct traffic.
public struct NetworkProxyStore {
    private let defaults: UserDefaults
    private let key = "runway.networkProxy"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> NetworkProxyConfiguration {
        guard let stored = defaults.object(forKey: key) else { return NetworkProxyConfiguration() }
        guard let data = stored as? Data else { throw NetworkProxyError.invalidConfiguration }
        do {
            let configuration = try JSONDecoder().decode(NetworkProxyConfiguration.self, from: data).validated()
            if configuration.usesAuthentication, configuration.credentialID == nil {
                throw NetworkProxyError.credentialsUnavailable
            }
            return configuration
        } catch let error as NetworkProxyError {
            throw error
        } catch {
            throw NetworkProxyError.invalidConfiguration
        }
    }

    public func save(_ configuration: NetworkProxyConfiguration) throws {
        let validated = try configuration.validated()
        if validated.usesAuthentication, validated.credentialID == nil {
            throw NetworkProxyError.credentialsUnavailable
        }
        do {
            defaults.set(try JSONEncoder().encode(validated), forKey: key)
        } catch {
            throw NetworkProxyError.invalidConfiguration
        }
    }
}
