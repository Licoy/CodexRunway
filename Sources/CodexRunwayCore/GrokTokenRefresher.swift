import Foundation

/// Refreshes Grok / xAI OAuth access tokens via the standard `refresh_token` grant.
///
/// Aligned with CLIProxyAPI `internal/auth/xai` (`grant_type=refresh_token` + `client_id`).
/// Writes never happen here — callers persist the returned auth.json bytes with the correct
/// home (managed copy only for non-current; official + managed for current).
public struct GrokTokenRefresher: Sendable {
    public var session: URLSession
    public var tokenURL: URL
    /// Refresh when remaining lifetime is at or below this skew (default 2 minutes).
    public var skewSeconds: TimeInterval
    public var clientIDFallback: String

    public init(
        session: URLSession = RunwayNetwork.session,
        tokenURL: URL = URL(string: "https://auth.x.ai/oauth2/token")!,
        skewSeconds: TimeInterval = 120,
        clientIDFallback: String = GrokOAuthLogin.clientID)
    {
        self.session = session
        self.tokenURL = tokenURL
        self.skewSeconds = max(0, skewSeconds)
        self.clientIDFallback = clientIDFallback
    }

    public struct EnsureResult: Sendable, Equatable {
        public var data: Data
        public var didRefresh: Bool
        public var document: GrokAuthDocument
    }

    /// Refresh only when the access token is missing/expired (within skew) and a refresh token exists.
    public func ensureFresh(_ data: Data, now: Date = Date()) async throws -> EnsureResult {
        let document = try GrokAuthDocument.parse(data)
        if !needsRefresh(document, now: now) {
            return EnsureResult(data: data, didRefresh: false, document: document)
        }
        guard document.identity.hasRefreshToken else {
            throw GrokCLIError.authenticationRequired
        }
        let refreshed = try await refresh(data, now: now)
        let refreshedDocument = try GrokAuthDocument.parse(refreshed)
        return EnsureResult(data: refreshed, didRefresh: true, document: refreshedDocument)
    }

    /// Always attempt a refresh_token exchange and merge the response into `data`.
    public func refresh(_ data: Data, now: Date = Date()) async throws -> Data {
        let document = try GrokAuthDocument.parse(data)
        let refreshToken = try document.refreshToken()
        let clientID = firstNonEmpty(document.identity.clientID, clientIDFallback)
            ?? GrokOAuthLogin.clientID
        let tokens = try await postRefresh(refreshToken: refreshToken, clientID: clientID)
        return try GrokAuthDocument.applyingTokenRefresh(
            to: data,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresIn: tokens.expiresIn,
            now: now)
    }

    public func needsRefresh(_ document: GrokAuthDocument, now: Date = Date()) -> Bool {
        if document.identity.kind == .legacySession {
            // Legacy session cookies cannot be OAuth-refreshed.
            return false
        }
        if !document.identity.hasAccessToken {
            return document.identity.hasRefreshToken
        }
        if let expiresAt = document.identity.expiresAt {
            return expiresAt.timeIntervalSince(now) <= skewSeconds
        }
        if let access = try? document.accessToken() {
            return TokenInspector.isExpired(access, now: now, skewSeconds: skewSeconds)
        }
        return document.identity.hasRefreshToken
    }

    private struct RefreshTokens: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Int?
    }

    private func postRefresh(refreshToken: String, clientID: String) async throws -> RefreshTokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken.urlFormEncoded)",
            "client_id=\(clientID.urlFormEncoded)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut || error.code == .cancelled {
            if error.code == .cancelled { throw CancellationError() }
            throw GrokCLIError.timeout(operation: "token-refresh")
        } catch {
            throw GrokCLIError.requestFailed(String(error.localizedDescription.prefix(200)))
        }

        guard let http = response as? HTTPURLResponse else {
            throw GrokCLIError.requestFailed("invalid token response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 400, 401, 403:
            throw GrokCLIError.authenticationRequired
        default:
            throw GrokCLIError.requestFailed("token HTTP \(http.statusCode)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokCLIError.malformedResponse("token refresh parse failed")
        }
        if let oauthError = nonEmptyString(object["error"]) {
            // Invalid/revoked refresh tokens must surface as re-auth.
            if oauthError == "invalid_grant" || oauthError == "invalid_token" || oauthError == "access_denied" {
                throw GrokCLIError.authenticationRequired
            }
            let description = nonEmptyString(object["error_description"]) ?? oauthError
            throw GrokCLIError.requestFailed(String(description.prefix(200)))
        }
        guard let accessToken = nonEmptyString(object["access_token"]) else {
            throw GrokCLIError.malformedResponse("token refresh missing access_token")
        }
        let expiresIn: Int?
        if let number = object["expires_in"] as? NSNumber {
            expiresIn = number.intValue
        } else if let text = object["expires_in"] as? String, let value = Int(text) {
            expiresIn = value
        } else {
            expiresIn = nil
        }
        return RefreshTokens(
            accessToken: accessToken,
            refreshToken: nonEmptyString(object["refresh_token"]),
            expiresIn: expiresIn)
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
