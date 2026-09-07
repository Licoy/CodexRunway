import Foundation

/// OpenAI / Codex OAuth (PKCE) constants and helpers. UI opens the auth URL and delivers the callback URL.
public enum CodexOAuthLogin {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    public static let scopes =
        "openid profile email offline_access api.connectors.read api.connectors.invoke"
    public static let originator = "codex_vscode"
    public static let preferredCallbackPort: UInt16 = 1455

    public struct Session: Sendable, Equatable {
        public var loginID: String
        public var authURL: URL
        public var redirectURI: String
        public var codeVerifier: String
        public var state: String
        public var port: UInt16
        public var expiresAt: Date
    }

    public struct TokenExchangeResult: Sendable, Equatable {
        public var auth: CodexAuth
    }

    public static func startSession(
        port: UInt16 = preferredCallbackPort,
        now: Date = Date(),
        lifetime: TimeInterval = 300) throws -> Session
    {
        let codeVerifier = randomBase64URL(bytes: 32)
        let challenge = codeChallenge(for: codeVerifier)
        let state = randomBase64URL(bytes: 16)
        let loginID = UUID().uuidString
        let redirectURI = "http://localhost:\(port)/auth/callback"
        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: originator),
        ]
        guard let authURL = components.url else {
            throw URLError(.badURL)
        }
        return Session(
            loginID: loginID,
            authURL: authURL,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier,
            state: state,
            port: port,
            expiresAt: now.addingTimeInterval(lifetime))
    }

    public static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            })
        if let error = items["error"] {
            throw URLError(.userAuthenticationRequired, userInfo: [
                NSLocalizedDescriptionKey: error,
            ])
        }
        guard let state = items["state"], state == expectedState else {
            throw URLError(.userAuthenticationRequired, userInfo: [
                NSLocalizedDescriptionKey: "OAuth state mismatch",
            ])
        }
        guard let code = items["code"], !code.isEmpty else {
            throw URLError(.userAuthenticationRequired, userInfo: [
                NSLocalizedDescriptionKey: "OAuth code missing",
            ])
        }
        return code
    }

    public static func exchangeCode(
        _ code: String,
        session: Session,
        urlSession: URLSession? = nil) async throws -> TokenExchangeResult
    {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=authorization_code",
            "client_id=\(clientID.urlFormEncoded)",
            "code=\(code.urlFormEncoded)",
            "redirect_uri=\(session.redirectURI.urlFormEncoded)",
            "code_verifier=\(session.codeVerifier.urlFormEncoded)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await RunwayNetwork.data(for: request, session: urlSession)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.userAuthenticationRequired)
        }
        let payload = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        let auth = CodexAuth(
            authMode: "chatgpt",
            tokens: .init(
                idToken: payload.idToken,
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken ?? "",
                accountId: CodexIdentityClaims.decode(payload.idToken)?.accountId
                    ?? CodexIdentityClaims.decode(payload.accessToken)?.accountId),
            lastRefresh: RunwayDates.string(Date()),
            planType: CodexIdentityClaims.decode(payload.idToken)?.planType
                ?? CodexIdentityClaims.decode(payload.accessToken)?.planType)
        guard auth.canRefreshOAuth || !auth.tokens.accessToken.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        return TokenExchangeResult(auth: auth)
    }

    private struct OAuthTokenResponse: Decodable {
        var idToken: String?
        var accessToken: String
        var refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private static func randomBase64URL(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return Data(buffer).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest).base64URLEncodedString()
    }
}

import CommonCrypto

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
