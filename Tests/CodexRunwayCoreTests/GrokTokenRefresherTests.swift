import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok token refresher", .serialized)
struct GrokTokenRefresherTests {
    @Test("skips refresh when access token is still valid")
    func skipsValidToken() async throws {
        let data = credential(
            email: "valid@example.com",
            userID: "valid-user",
            expiresAt: "2099-08-01T12:00:00Z",
            accessToken: "still-valid-access",
            refreshToken: "refresh-token-for-tests")
        let hits = RequestHitCounter()
        MockGrokTokenURLProtocol.handler = { _ in
            await hits.increment()
            return (
                HTTPURLResponse(
                    url: URL(string: "https://auth.x.ai/oauth2/token")!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil)!,
                Data())
        }
        defer { MockGrokTokenURLProtocol.handler = nil }

        let refresher = GrokTokenRefresher(
            session: MockGrokTokenURLProtocol.session(),
            tokenURL: URL(string: "https://auth.x.ai/oauth2/token")!)
        let result = try await refresher.ensureFresh(data, now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(result.didRefresh == false)
        #expect(result.data == data)
        #expect(await hits.count == 0)
    }

    @Test("refreshes expired access token and merges new tokens into auth.json")
    func refreshesExpiredToken() async throws {
        let data = credential(
            email: "expired@example.com",
            userID: "expired-user",
            expiresAt: "2020-01-01T00:00:00Z",
            accessToken: "expired-access-token",
            refreshToken: "refresh-token-for-tests")
        MockGrokTokenURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path.contains("token") == true)
            let response = Data(
                #"""
                {
                  "access_token": "new-access-token-for-tests",
                  "refresh_token": "rotated-refresh-token-for-tests",
                  "expires_in": 3600,
                  "token_type": "Bearer"
                }
                """#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                response)
        }
        defer { MockGrokTokenURLProtocol.handler = nil }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let refresher = GrokTokenRefresher(
            session: MockGrokTokenURLProtocol.session(),
            tokenURL: URL(string: "https://auth.x.ai/oauth2/token")!)
        let result = try await refresher.ensureFresh(data, now: now)

        #expect(result.didRefresh)
        #expect(try result.document.accessToken() == "new-access-token-for-tests")
        #expect(try result.document.refreshToken() == "rotated-refresh-token-for-tests")
        #expect(result.document.identity.expiresAt == now.addingTimeInterval(3_600))
        // Sibling scopes (none here) and identity fields survive.
        #expect(result.document.identity.email == "expired@example.com")
        #expect(result.document.identity.userID == "expired-user")
    }

    @Test("preserves sibling scopes when refreshing the managed OAuth scope")
    func preservesSiblingScopes() async throws {
        var root: [String: Any] = try JSONSerialization.jsonObject(
            with: credential(
                email: "multi@example.com",
                userID: "multi-user",
                expiresAt: "2020-01-01T00:00:00Z",
                accessToken: "old",
                refreshToken: "refresh-token-for-tests")) as! [String: Any]
        root[GrokAuthDocument.apiKeyScope] = [
            "auth_mode": "api_key",
            "key": "xai-api-key-for-tests-only",
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        MockGrokTokenURLProtocol.handler = { request in
            let response = Data(#"{"access_token":"fresh-access","expires_in":1800}"#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!,
                response)
        }
        defer { MockGrokTokenURLProtocol.handler = nil }

        let refresher = GrokTokenRefresher(session: MockGrokTokenURLProtocol.session())
        let refreshed = try await refresher.refresh(data, now: Date())
        let parsed = try JSONSerialization.jsonObject(with: refreshed) as? [String: Any]
        let api = parsed?[GrokAuthDocument.apiKeyScope] as? [String: Any]
        #expect(api?["key"] as? String == "xai-api-key-for-tests-only")
        #expect(try GrokAuthDocument.accessToken(from: refreshed) == "fresh-access")
    }

    @Test("invalid_grant becomes authentication required")
    func invalidGrantMapsToAuthRequired() async throws {
        let data = credential(
            email: "revoked@example.com",
            userID: "revoked-user",
            expiresAt: "2020-01-01T00:00:00Z",
            accessToken: "old",
            refreshToken: "revoked-refresh")
        MockGrokTokenURLProtocol.handler = { request in
            let response = Data(#"{"error":"invalid_grant","error_description":"Token has been revoked"}"#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil)!,
                response)
        }
        defer { MockGrokTokenURLProtocol.handler = nil }

        let refresher = GrokTokenRefresher(session: MockGrokTokenURLProtocol.session())
        await #expect(throws: GrokCLIError.authenticationRequired) {
            _ = try await refresher.ensureFresh(data, now: Date())
        }
    }

    @Test("needsRefresh uses JWT exp when expires_at is absent")
    func needsRefreshUsesJWTExp() throws {
        // JWT payload {"exp":100} — expired relative to now.
        let jwt = "eyJhbGciOiJub25lIn0.eyJleHAiOjEwMH0.sig"
        let data = credential(
            email: "jwt@example.com",
            userID: "jwt-user",
            expiresAt: nil,
            accessToken: jwt,
            refreshToken: "refresh-token-for-tests")
        let document = try GrokAuthDocument.parse(data)
        let refresher = GrokTokenRefresher()
        #expect(refresher.needsRefresh(document, now: Date(timeIntervalSince1970: 1_000)))
        // Far-future JWT exp.
        let futureJWT = "eyJhbGciOiJub25lIn0.\(base64URL(["exp": 4_000_000_000])).sig"
        let futureData = credential(
            email: "jwt2@example.com",
            userID: "jwt2-user",
            expiresAt: nil,
            accessToken: futureJWT,
            refreshToken: "refresh-token-for-tests")
        let futureDocument = try GrokAuthDocument.parse(futureData)
        #expect(refresher.needsRefresh(futureDocument, now: Date(timeIntervalSince1970: 1_800_000_000)) == false)
    }

    private func credential(
        email: String,
        userID: String,
        expiresAt: String?,
        accessToken: String,
        refreshToken: String) -> Data
    {
        var credential: [String: Any] = [
            "auth_mode": "oidc",
            "email": email,
            "key": accessToken,
            "oidc_client_id": GrokOAuthLogin.clientID,
            "oidc_issuer": "https://auth.x.ai",
            "principal_id": "principal-\(userID)",
            "principal_type": "User",
            "refresh_token": refreshToken,
            "user_id": userID,
        ]
        if let expiresAt {
            credential["expires_at"] = expiresAt
        }
        let root: [String: Any] = [
            "\(GrokAuthDocument.oauthScopePrefix)\(GrokOAuthLogin.clientID)": credential,
        ]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func base64URL(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private actor RequestHitCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private final class MockGrokTokenURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGrokTokenURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // Mirror MockBillingURLProtocol: keep the URLProtocol client callbacks on this
        // instance without isolating through a Sendable capture of `self`.
        let request = self.request
        NonisolatedURLProtocolResponder.fulfill(request: request, handler: handler, protocol: self)
    }

    override func stopLoading() {}
}

/// Bridges async mock handlers back to URLProtocol without a sending-`self` Task capture.
private enum NonisolatedURLProtocolResponder {
    nonisolated static func fulfill(
        request: URLRequest,
        handler: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data),
        protocol urlProtocol: URLProtocol)
    {
        let client = urlProtocol.client
        // URLProtocol is not Sendable; the mock is single-session and serialised by suite.
        nonisolated(unsafe) let protocolInstance = urlProtocol
        Task {
            do {
                let (response, data) = try await handler(request)
                client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(protocolInstance, didLoad: data)
                client?.urlProtocolDidFinishLoading(protocolInstance)
            } catch {
                client?.urlProtocol(protocolInstance, didFailWithError: error)
            }
        }
    }
}
