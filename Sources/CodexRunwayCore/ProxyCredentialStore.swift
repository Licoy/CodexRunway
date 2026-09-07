import Foundation
import Security

/// Only opaque identifiers leave this store; proxy secrets never enter preferences or exports.
public struct ProxyCredentialStore {
    private static let interactionLock = NSLock()
    private let read: (String, Bool) throws -> NetworkProxyCredentials
    private let write: (NetworkProxyCredentials, String) throws -> Void
    private let remove: (String) throws -> Void

    public init(service: String = ProxyCredentialStore.defaultService) {
        read = { id, interactive in
            var query = Self.query(service: service, id: id)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = try Self.copyMatching(query, allowInteraction: interactive)
            guard status == errSecSuccess, let data = result as? Data else {
                throw NetworkProxyError.credentialsUnavailable
            }
            do { return try JSONDecoder().decode(NetworkProxyCredentials.self, from: data) }
            catch { throw NetworkProxyError.credentialsUnavailable }
        }
        write = { credentials, id in
            Self.interactionLock.lock()
            defer { Self.interactionLock.unlock() }
            guard UUID(uuidString: id) != nil else { throw NetworkProxyError.invalidConfiguration }
            let data = try JSONEncoder().encode(credentials)
            let query = Self.query(service: service, id: id)
            let values = [kSecValueData as String: data] as CFDictionary
            var status = SecItemUpdate(query as CFDictionary, values)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw NetworkProxyError.credentialStoreFailed }
        }
        remove = { id in
            Self.interactionLock.lock()
            defer { Self.interactionLock.unlock() }
            let status = SecItemDelete(Self.query(service: service, id: id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NetworkProxyError.credentialStoreFailed
            }
        }
    }

    // A narrow storage seam keeps tests away from the user's real Keychain.
    public init(
        load: @escaping (String, Bool) throws -> NetworkProxyCredentials,
        save: @escaping (NetworkProxyCredentials, String) throws -> Void,
        delete: @escaping (String) throws -> Void)
    {
        read = load
        write = save
        remove = delete
    }

    public static var defaultService: String {
        "\(Bundle.main.bundleIdentifier ?? "com.github.codex-runway.swift-dev").network-proxy"
    }

    public func load(id: String, allowInteraction: Bool = false) throws -> NetworkProxyCredentials {
        guard UUID(uuidString: id) != nil else { throw NetworkProxyError.credentialsUnavailable }
        return try read(id, allowInteraction)
    }

    public func save(_ credentials: NetworkProxyCredentials, id: String) throws {
        try write(credentials, id)
    }

    public func delete(id: String) throws { try remove(id) }

    private static func copyMatching(
        _ query: [String: Any],
        allowInteraction: Bool) throws -> (OSStatus, CFTypeRef?)
    {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var previous = DarwinBoolean(false)
        // Ad-hoc builds use the legacy Keychain, which ignores LAContext.interactionNotAllowed.
        // Its public, process-local interaction switch is required despite the deprecation;
        // serialize all of our Keychain operations and restore it before returning.
        if !allowInteraction {
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess
            else { throw NetworkProxyError.credentialsUnavailable }
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if !allowInteraction,
           SecKeychainSetUserInteractionAllowed(previous.boolValue) != errSecSuccess
        {
            throw NetworkProxyError.credentialStoreFailed
        }
        return (status, result)
    }

    private static func query(service: String, id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
