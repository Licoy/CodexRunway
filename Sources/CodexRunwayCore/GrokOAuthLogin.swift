import Foundation

/// xAI / Grok OAuth device-code login (RFC 8628), aligned with CLIProxyAPI's `internal/auth/xai`.
///
/// Official `grok login --oauth` relies on a TTY loopback callback and often fails to open a browser
/// when spawned from a menu-bar (LSUIElement) app with stdio discarded. Device-code auth requests a
/// verification URL, opens it with `/usr/bin/open`, polls for tokens, then writes a Grok-compatible
/// `auth.json` under the isolated account home.
public enum GrokOAuthLogin {
    public static let issuer = "https://auth.x.ai"
    public static let discoveryURL = URL(string: "\(issuer)/.well-known/openid-configuration")!
    /// Public Grok CLI OAuth client ID (same as CLIProxyAPI / official Grok device auth).
    public static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let scope = "openid profile email offline_access grok-cli:access api:access"
    public static let deviceCodeGrantType = "urn:ietf:params:oauth:grant-type:device_code"
    public static let defaultPollInterval: TimeInterval = 5
    public static let maxPollDuration: TimeInterval = 30 * 60

    public struct DeviceCode: Sendable, Equatable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURI: URL
        public var verificationURIComplete: URL?
        public var expiresIn: TimeInterval
        public var interval: TimeInterval
        public var tokenEndpoint: URL

        public var browserURL: URL {
            verificationURIComplete ?? verificationURI
        }
    }

    public struct TokenBundle: Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
        public var idToken: String?
        public var tokenType: String?
        public var expiresIn: Int?
        public var email: String?
        public var subject: String?
        public var tokenEndpoint: URL
    }

    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        case discoveryFailed(String)
        case invalidEndpoint(String)
        case deviceCodeFailed(String)
        case authorizationPending
        case slowDown
        case expired
        case denied
        case tokenFailed(String)
        case missingIdentity
        case writeFailed(String)
        case browserOpenFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .discoveryFailed(message):
                "Grok OAuth discovery failed: \(message)"
            case let .invalidEndpoint(message):
                "Grok OAuth endpoint invalid: \(message)"
            case let .deviceCodeFailed(message):
                "Grok device authorization failed: \(message)"
            case .authorizationPending:
                "Grok device authorization is still pending."
            case .slowDown:
                "Grok device authorization polling must slow down."
            case .expired:
                "Grok device code expired."
            case .denied:
                "Grok device authorization was denied."
            case let .tokenFailed(message):
                "Grok token exchange failed: \(message)"
            case .missingIdentity:
                "Grok OAuth response did not include a user identity."
            case let .writeFailed(message):
                "Unable to write Grok credentials: \(message)"
            case let .browserOpenFailed(message):
                "Unable to open the browser: \(message)"
            }
        }
    }

    public typealias OpenURL = @Sendable (URL) throws -> Void
    public typealias DeviceCodeHandler = @Sendable (DeviceCode) -> Void

    /// Run device-code login and write `auth.json` into `homeURL` (mode `0600`).
    public static func login(
        homeURL: URL,
        session: URLSession = RunwayNetwork.session,
        openURL: @escaping OpenURL = openInDefaultBrowser,
        now: @escaping @Sendable () -> Date = Date.init,
        onDeviceCode: DeviceCodeHandler? = nil) async throws
    {
        let device = try await startDeviceFlow(session: session)
        onDeviceCode?(device)
        do {
            try openURL(device.browserURL)
        } catch {
            // Browser open is best-effort; the user can still visit the URL manually if surfaced.
            // Do not abort the poll — device codes remain valid.
            _ = error
        }
        let tokens = try await waitForAuthorization(device: device, session: session)
        let data = try makeAuthDocumentData(tokens: tokens, now: now())
        try writeAuthJSON(data, homeURL: homeURL)
    }

    public static func startDeviceFlow(session: URLSession = RunwayNetwork.session) async throws -> DeviceCode {
        let discovery = try await discover(session: session)
        return try await requestDeviceCode(
            deviceAuthorizationEndpoint: discovery.deviceAuthorizationEndpoint,
            tokenEndpoint: discovery.tokenEndpoint,
            session: session)
    }

    public static func waitForAuthorization(
        device: DeviceCode,
        session: URLSession = RunwayNetwork.session) async throws -> TokenBundle
    {
        var interval = max(device.interval, defaultPollInterval)
        let codeDeadline = Date().addingTimeInterval(max(1, device.expiresIn))
        let hardDeadline = Date().addingTimeInterval(maxPollDuration)
        let deadline = min(codeDeadline, hardDeadline)
        var firstAttempt = true

        while true {
            try Task.checkCancellation()
            if !firstAttempt, Date() > deadline {
                throw Error.expired
            }
            if !firstAttempt {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                try Task.checkCancellation()
            }
            firstAttempt = false

            do {
                return try await exchangeDeviceCode(
                    deviceCode: device.deviceCode,
                    tokenEndpoint: device.tokenEndpoint,
                    session: session)
            } catch Error.authorizationPending {
                continue
            } catch Error.slowDown {
                interval += defaultPollInterval
                continue
            }
        }
    }

    public static func openInDefaultBrowser(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Error.browserOpenFailed(error.localizedDescription)
        }
    }

    // MARK: - Discovery / device / token

    private struct Discovery: Sendable {
        var deviceAuthorizationEndpoint: URL
        var tokenEndpoint: URL
    }

    private static func discover(session: URLSession) async throws -> Discovery {
        var request = URLRequest(url: discoveryURL)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.discoveryFailed(String(error.localizedDescription.prefix(200)))
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw Error.discoveryFailed("HTTP \(status)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.discoveryFailed("invalid JSON")
        }
        let deviceRaw = stringValue(object["device_authorization_endpoint"])
        let tokenRaw = stringValue(object["token_endpoint"])
        let deviceURL = try validateOAuthEndpoint(deviceRaw, field: "device_authorization_endpoint")
        let tokenURL = try validateOAuthEndpoint(tokenRaw, field: "token_endpoint")
        return Discovery(deviceAuthorizationEndpoint: deviceURL, tokenEndpoint: tokenURL)
    }

    private static func requestDeviceCode(
        deviceAuthorizationEndpoint: URL,
        tokenEndpoint: URL,
        session: URLSession) async throws -> DeviceCode
    {
        var request = URLRequest(url: deviceAuthorizationEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(
            "client_id=\(clientID.urlFormEncoded)&scope=\(scope.urlFormEncoded)".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.deviceCodeFailed(String(error.localizedDescription.prefix(200)))
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Error.deviceCodeFailed("HTTP \(status) \(String(body.prefix(200)))")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.deviceCodeFailed("invalid JSON")
        }
        guard let deviceCode = stringValue(object["device_code"]),
              let userCode = stringValue(object["user_code"])
        else {
            throw Error.deviceCodeFailed("missing device_code or user_code")
        }
        let verificationRaw = stringValue(object["verification_uri"])
            ?? stringValue(object["verification_uri_complete"])
        guard let verificationRaw,
              let verificationURI = URL(string: verificationRaw),
              let scheme = verificationURI.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            throw Error.deviceCodeFailed("missing or invalid verification_uri")
        }
        let completeRaw = stringValue(object["verification_uri_complete"])
        let completeURL = completeRaw.flatMap(URL.init(string:))
        let expiresIn = numberValue(object["expires_in"]).map(TimeInterval.init) ?? 1_800
        let interval = numberValue(object["interval"]).map(TimeInterval.init) ?? defaultPollInterval
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            verificationURIComplete: completeURL,
            expiresIn: expiresIn,
            interval: interval,
            tokenEndpoint: tokenEndpoint)
    }

    private static func exchangeDeviceCode(
        deviceCode: String,
        tokenEndpoint: URL,
        session: URLSession) async throws -> TokenBundle
    {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "grant_type=\(deviceCodeGrantType.urlFormEncoded)",
            "device_code=\(deviceCode.urlFormEncoded)",
            "client_id=\(clientID.urlFormEncoded)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.tokenFailed(String(error.localizedDescription.prefix(200)))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.tokenFailed("invalid JSON")
        }
        if let oauthError = stringValue(object["error"]) {
            switch oauthError {
            case "authorization_pending":
                throw Error.authorizationPending
            case "slow_down":
                throw Error.slowDown
            case "expired_token":
                throw Error.expired
            case "access_denied":
                throw Error.denied
            default:
                let description = stringValue(object["error_description"]) ?? oauthError
                throw Error.tokenFailed(description)
            }
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw Error.tokenFailed("HTTP \(status)")
        }
        guard let accessToken = stringValue(object["access_token"]) else {
            throw Error.tokenFailed("missing access_token")
        }
        let idToken = stringValue(object["id_token"])
        let claims = jwtClaims(idToken)
        let email = stringValue(object["email"])
            ?? stringValue(claims?["email"])
        let subject = stringValue(object["sub"])
            ?? stringValue(claims?["sub"])
        return TokenBundle(
            accessToken: accessToken,
            refreshToken: stringValue(object["refresh_token"]) ?? "",
            idToken: idToken,
            tokenType: stringValue(object["token_type"]),
            expiresIn: numberValue(object["expires_in"]),
            email: email,
            subject: subject,
            tokenEndpoint: tokenEndpoint)
    }

    // MARK: - Auth document

    public static func makeAuthDocumentData(tokens: TokenBundle, now: Date = Date()) throws -> Data {
        let email = firstNonEmpty(tokens.email)
        let subject = firstNonEmpty(tokens.subject)
        guard firstNonEmpty(subject, email) != nil else {
            throw Error.missingIdentity
        }
        let userID = subject ?? "email-\(AccountIdentity.stableHash((email ?? "").lowercased()))"
        let principalID = subject ?? userID
        let expiresAt: String?
        if let expiresIn = tokens.expiresIn, expiresIn > 0 {
            expiresAt = iso8601String(now.addingTimeInterval(TimeInterval(expiresIn)))
        } else {
            expiresAt = nil
        }

        var credential: [String: Any] = [
            "auth_mode": "oidc",
            "create_time": iso8601String(now),
            "key": tokens.accessToken,
            "oidc_client_id": clientID,
            "oidc_issuer": issuer,
            "principal_id": principalID,
            "principal_type": "User",
            "user_id": userID,
        ]
        if let email {
            credential["email"] = email
        }
        if !tokens.refreshToken.isEmpty {
            credential["refresh_token"] = tokens.refreshToken
        }
        if let expiresAt {
            credential["expires_at"] = expiresAt
        }

        let scopeKey = "\(GrokAuthDocument.oauthScopePrefix)\(clientID)"
        let root: [String: Any] = [scopeKey: credential]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                  withJSONObject: root,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? GrokAuthDocument.parse(data)) != nil
        else {
            throw Error.writeFailed("unable to encode Grok auth.json")
        }
        return data
    }

    private static func writeAuthJSON(_ data: Data, homeURL: URL) throws {
        do {
            try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700 as UInt16)],
                ofItemAtPath: homeURL.path)
            let authURL = homeURL.appendingPathComponent("auth.json")
            let temporary = homeURL.appendingPathComponent(".auth.json.tmp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600 as UInt16)],
                ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: authURL.path) {
                _ = try FileManager.default.replaceItemAt(authURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: authURL)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600 as UInt16)],
                ofItemAtPath: authURL.path)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func validateOAuthEndpoint(_ raw: String?, field: String) throws -> URL {
        guard let raw, !raw.isEmpty, let url = URL(string: raw) else {
            throw Error.invalidEndpoint("\(field) is empty")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw Error.invalidEndpoint("\(field) must use https")
        }
        let host = (url.host ?? "").lowercased()
        guard host == "x.ai" || host.hasSuffix(".x.ai") else {
            throw Error.invalidEndpoint("\(field) host is not on x.ai")
        }
        return url
    }

    private static func jwtClaims(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let text = value as? String, let value = Int(text) { return value }
        return nil
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
