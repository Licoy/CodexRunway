import Foundation

public struct TokenRefresher: Sendable {
    public var session: URLSession
    public var tokenURL: URL

    public init(
        session: URLSession = RunwayNetwork.session,
        tokenURL: URL = URL(string: "https://auth.openai.com/oauth/token")!)
    {
        self.session = session
        self.tokenURL = tokenURL
    }

    public func refresh(_ auth: inout CodexAuth, store: CodexAuthStore? = nil) async throws {
        guard !auth.tokens.refreshToken.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        // Prefer client_id (Codex OAuth); fall back without it for older token grants.
        if let data = try? await postRefresh(refreshToken: auth.tokens.refreshToken, includeClientID: true) {
            try auth.mergeRefreshResponse(data)
            try store?.save(auth)
            return
        }
        let data = try await postRefresh(refreshToken: auth.tokens.refreshToken, includeClientID: false)
        try auth.mergeRefreshResponse(data)
        try store?.save(auth)
    }

    private func postRefresh(refreshToken: String, includeClientID: Bool) async throws -> Data {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parts = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken.urlFormEncoded)",
        ]
        if includeClientID {
            parts.append("client_id=\(CodexOAuthLogin.clientID.urlFormEncoded)")
        }
        request.httpBody = Data(parts.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.userAuthenticationRequired)
        }
        return data
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
