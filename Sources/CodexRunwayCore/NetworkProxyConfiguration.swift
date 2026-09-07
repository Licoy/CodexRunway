import Darwin
import Foundation

public enum NetworkProxyMode: String, Codable, CaseIterable, Sendable {
    case system
    case http
    case socks5
}

public struct NetworkProxyConfiguration: Codable, Equatable, Sendable {
    public var mode: NetworkProxyMode
    public var host: String
    public var port: Int
    public var usesAuthentication: Bool
    public var credentialID: String?

    public init(
        mode: NetworkProxyMode = .system,
        host: String = "",
        port: Int = 0,
        usesAuthentication: Bool = false,
        credentialID: String? = nil)
    {
        self.mode = mode
        self.host = host
        self.port = port
        self.usesAuthentication = usesAuthentication
        self.credentialID = credentialID
    }

    public func validated() throws -> Self {
        guard mode != .system else { return Self() }
        guard (1...65_535).contains(port) else { throw NetworkProxyError.invalidPort }
        var result = self
        result.host = try Self.normalizedHost(host)
        if !usesAuthentication { result.credentialID = nil }
        if let id = result.credentialID, UUID(uuidString: id) == nil {
            throw NetworkProxyError.invalidConfiguration
        }
        return result
    }

    private static func normalizedHost(_ raw: String) throws -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            guard host.contains(":") else { throw NetworkProxyError.invalidHost }
        }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !host.contains(where: { "/\\@?#%[]".contains($0) })
        else { throw NetworkProxyError.invalidHost }
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { throw NetworkProxyError.invalidHost }
            return host.lowercased()
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            var address = in_addr()
            guard inet_pton(AF_INET, host, &address) == 1 else { throw NetworkProxyError.invalidHost }
            return host
        }
        // URLComponents supplies the platform's IDNA normalization without allowing URL userinfo.
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        guard let normalized = components.url?.host?.lowercased() else {
            throw NetworkProxyError.invalidHost
        }
        let labels = normalized.hasSuffix(".") ? normalized.dropLast().split(separator: ".", omittingEmptySubsequences: false)
            : normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { byte in
                    (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
                }
        }) else { throw NetworkProxyError.invalidHost }
        return normalized
    }
}

public struct NetworkProxyCredentials: Codable, Equatable, Sendable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public func validated(for mode: NetworkProxyMode) throws -> Self {
        guard !username.isEmpty,
              !username.contains(where: { $0.isNewline || $0 == "\0" }),
              !password.contains(where: { $0.isNewline || $0 == "\0" })
        else { throw NetworkProxyError.invalidCredentials }
        if mode == .http, username.contains(":") { throw NetworkProxyError.invalidCredentials }
        if mode == .socks5,
           !(1...255).contains(username.utf8.count) || !(1...255).contains(password.utf8.count)
        {
            throw NetworkProxyError.invalidCredentials
        }
        return self
    }
}

public enum NetworkProxyError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration, invalidHost, invalidPort, invalidCredentials
    case credentialsUnavailable, credentialStoreFailed, connectionFailed, authenticationFailed
    case notReady, updateBridgeUnavailable, invalidUpdateURL

    public var l10nKey: L10nKey {
        switch self {
        case .invalidConfiguration: .proxyInvalidConfiguration
        case .invalidHost: .proxyInvalidHost
        case .invalidPort: .proxyInvalidPort
        case .invalidCredentials: .proxyInvalidCredentials
        case .credentialsUnavailable: .proxyCredentialsUnavailable
        case .credentialStoreFailed: .proxyCredentialStoreFailed
        case .connectionFailed: .proxyConnectionFailed
        case .authenticationFailed: .proxyAuthenticationFailed
        case .notReady: .proxyNotReady
        case .updateBridgeUnavailable: .updateProxyUnavailable
        case .invalidUpdateURL: .proxyInvalidUpdateURL
        }
    }

    public var errorDescription: String? { L10n(preference: .system).text(l10nKey) }
}
